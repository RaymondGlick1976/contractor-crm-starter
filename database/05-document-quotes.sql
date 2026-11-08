-- =====================================================================
-- YOURCRM — part 5: "Attached document" quotes & invoices
-- A quote/invoice can be itemized (line items) or an uploaded document
-- (PDF/image) with a manually entered total. Deposits, payment schedules,
-- payment links, portal and Stripe all work off that total.
-- =====================================================================
SET search_path = public, extensions;

ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS document_mode text NOT NULL DEFAULT 'itemized'
    CHECK (document_mode IN ('itemized','attachment')),
  ADD COLUMN IF NOT EXISTS manual_total numeric(10,2);

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS document_mode text NOT NULL DEFAULT 'itemized'
    CHECK (document_mode IN ('itemized','attachment')),
  ADD COLUMN IF NOT EXISTS manual_total numeric(10,2);

-- Files attached to an invoice (mirrors quote_attachments)
CREATE TABLE IF NOT EXISTS public.invoice_attachments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  file_url text NOT NULL,
  file_name varchar(255) NOT NULL,
  file_type varchar(100),
  file_size integer,
  display_order integer DEFAULT 0,
  uploaded_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_invoice_attachments_invoice ON public.invoice_attachments(invoice_id);
CREATE TRIGGER aa_fill_org_id BEFORE INSERT ON public.invoice_attachments
  FOR EACH ROW EXECUTE FUNCTION public.fill_org_id('invoice_id', 'invoices');
ALTER TABLE public.invoice_attachments ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON public.invoice_attachments FOR ALL TO authenticated
  USING (org_id = (SELECT current_org_id())) WITH CHECK (org_id = (SELECT current_org_id()));

-- ---------------------------------------------------------------------
-- Quotes: in attachment mode the manual total IS the total (tax included)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_quote_manual_total()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.document_mode = 'attachment' THEN
    NEW.manual_total    := ROUND(GREATEST(COALESCE(NEW.manual_total, 0), 0), 2);
    NEW.subtotal        := NEW.manual_total;
    NEW.subtotal_low    := NULL;
    NEW.subtotal_high   := NULL;
    NEW.total_low       := NULL;
    NEW.total_high      := NULL;
    NEW.tax_rate        := 0;
    NEW.tax_amount      := 0;
    NEW.discount_value  := 0;
    NEW.discount_amount := 0;
    NEW.total           := NEW.manual_total;
    NEW.packages_enabled := false;
    NEW.deposit_amount  := CASE WHEN NEW.deposit_type = 'fixed' THEN LEAST(COALESCE(NEW.deposit_value, 0), NEW.manual_total)
                                ELSE ROUND(NEW.manual_total * COALESCE(NEW.deposit_value, 0) / 100, 2) END;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ac_apply_quote_manual_total BEFORE INSERT OR UPDATE ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION apply_quote_manual_total();

-- Line-item recalculation must not overwrite a manual total
CREATE OR REPLACE FUNCTION public.update_quote_totals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  q RECORD;
  s numeric(10,2); s_low numeric(10,2); s_high numeric(10,2);
  has_ranges boolean; dep numeric(10,2);
BEGIN
  SELECT * INTO q FROM quotes WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
  IF q IS NULL OR q.document_mode = 'attachment' THEN RETURN NEW; END IF;
  SELECT
    COALESCE(SUM(CASE WHEN NOT is_optional OR is_selected THEN line_total ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN NOT is_optional OR is_selected THEN COALESCE(line_total_low, line_total) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN NOT is_optional OR is_selected THEN COALESCE(line_total_high, line_total) ELSE 0 END), 0),
    BOOL_OR(is_range_pricing)
  INTO s, s_low, s_high, has_ranges
  FROM quote_line_items WHERE quote_id = q.id;

  IF q.deposit_type = 'percentage' THEN dep := s_low * (q.deposit_value / 100);
  ELSE dep := q.deposit_value; END IF;

  UPDATE quotes SET
    subtotal = s,
    subtotal_low = CASE WHEN has_ranges THEN s_low END,
    subtotal_high = CASE WHEN has_ranges THEN s_high END,
    tax_amount = s * q.tax_rate,
    total = s + s * q.tax_rate,
    total_low = CASE WHEN has_ranges THEN s_low + s_low * q.tax_rate END,
    total_high = CASE WHEN has_ranges THEN s_high + s_high * q.tax_rate END,
    deposit_amount = dep,
    updated_at = now()
  WHERE id = q.id;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Invoices
-- ---------------------------------------------------------------------
-- An invoice created from an attachment-mode quote inherits the mode + total
CREATE OR REPLACE FUNCTION public.inherit_invoice_document_mode()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q RECORD;
BEGIN
  IF NEW.quote_id IS NOT NULL AND COALESCE(NEW.document_mode, 'itemized') = 'itemized' AND NEW.manual_total IS NULL THEN
    SELECT document_mode, manual_total INTO q FROM quotes WHERE id = NEW.quote_id;
    IF q.document_mode = 'attachment' THEN
      NEW.document_mode := 'attachment';
      NEW.manual_total := q.manual_total;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ab_inherit_invoice_document_mode BEFORE INSERT ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION inherit_invoice_document_mode();

CREATE OR REPLACE FUNCTION public.apply_invoice_manual_total()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.document_mode = 'attachment' THEN
    NEW.manual_total    := ROUND(GREATEST(COALESCE(NEW.manual_total, 0), 0), 2);
    NEW.subtotal        := NEW.manual_total;
    NEW.tax_rate        := 0;
    NEW.tax_amount      := 0;
    NEW.discount_value  := 0;
    NEW.discount_amount := 0;
    NEW.total           := NEW.manual_total;
    NEW.amount_due      := NEW.manual_total - COALESCE(NEW.amount_paid, 0);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ac_apply_invoice_manual_total BEFORE INSERT OR UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION apply_invoice_manual_total();

-- Copy the quote's document(s) onto the new invoice
CREATE OR REPLACE FUNCTION public.copy_quote_attachments_to_invoice()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.document_mode = 'attachment' AND NEW.quote_id IS NOT NULL THEN
    INSERT INTO invoice_attachments (org_id, invoice_id, file_url, file_name, file_type, file_size, display_order)
    SELECT NEW.org_id, NEW.id, file_url, file_name, file_type, file_size, display_order
      FROM quote_attachments WHERE quote_id = NEW.quote_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_copy_quote_attachments_to_invoice AFTER INSERT ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION copy_quote_attachments_to_invoice();

-- Line-item recalculation must not overwrite a manual total
CREATE OR REPLACE FUNCTION public.update_invoice_totals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  inv RECORD;
  c_sub numeric(10,2); c_tax_base numeric(10,2); c_disc_base numeric(10,2); c_tax_disc numeric(10,2);
  c_disc numeric(10,2); share numeric; c_tax numeric(10,2); c_total numeric(10,2);
BEGIN
  SELECT * INTO inv FROM invoices WHERE id = COALESCE(NEW.invoice_id, OLD.invoice_id);
  IF inv IS NULL OR inv.document_mode = 'attachment' THEN RETURN NEW; END IF;
  SELECT COALESCE(SUM(line_total),0),
         COALESCE(SUM(line_total) FILTER (WHERE is_taxable),0),
         COALESCE(SUM(line_total) FILTER (WHERE apply_discount IS DISTINCT FROM false),0),
         COALESCE(SUM(line_total) FILTER (WHERE is_taxable AND apply_discount IS DISTINCT FROM false),0)
    INTO c_sub, c_tax_base, c_disc_base, c_tax_disc
    FROM invoice_line_items WHERE invoice_id = inv.id;

  IF inv.discount_type = 'fixed' THEN c_disc := LEAST(COALESCE(inv.discount_value,0), c_disc_base);
  ELSE c_disc := c_disc_base * COALESCE(inv.discount_value,0) / 100; END IF;
  c_disc := ROUND(GREATEST(c_disc, 0), 2);
  share := CASE WHEN c_disc_base > 0 THEN c_tax_disc / c_disc_base ELSE 0 END;
  c_tax := GREATEST(0, c_tax_base - c_disc * share) * COALESCE(inv.tax_rate, 0);
  c_total := c_sub - c_disc + c_tax;

  UPDATE invoices SET subtotal = c_sub, discount_amount = c_disc, tax_amount = c_tax,
         total = c_total, amount_due = c_total - amount_paid, updated_at = now()
   WHERE id = inv.id;
  RETURN NEW;
END $$;
