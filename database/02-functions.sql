-- =====================================================================
-- YOURCRM — part 2: tenancy helpers, business logic, views
-- =====================================================================
SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- TENANCY HELPERS
-- ---------------------------------------------------------------------

-- The organization the signed-in user is working in (NULL for anon/service role).
CREATE OR REPLACE FUNCTION public.current_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT p.active_org_id
       FROM profiles p
       JOIN app_users u ON u.org_id = p.active_org_id AND u.user_id = p.user_id AND u.is_active
      WHERE p.user_id = auth.uid()),
    (SELECT u.org_id FROM app_users u
      WHERE u.user_id = auth.uid() AND u.is_active
      ORDER BY u.created_at LIMIT 1)
  );
$$;

-- Does the signed-in user hold a role with this permission in the current org?
CREATE OR REPLACE FUNCTION public.has_org_permission(p_perm text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT (to_jsonb(r) ->> p_perm)::boolean
      FROM app_users u JOIN app_roles r ON r.id = u.role_id
     WHERE u.user_id = auth.uid() AND u.org_id = current_org_id() AND u.is_active
     LIMIT 1), false);
$$;

-- Legacy name used by older policies/pages
CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT current_org_id() IS NOT NULL;
$$;

-- Fills NEW.org_id: from a parent row (trigger args: fk_column, parent_table, ...)
-- or from the signed-in user's active org. Lets client code and server code
-- insert rows without knowing about org_id.
CREATE OR REPLACE FUNCTION public.fill_org_id()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  i int := 0;
  v_ref text;
  v_org uuid;
BEGIN
  IF NEW.org_id IS NOT NULL THEN RETURN NEW; END IF;
  WHILE i + 1 < TG_NARGS LOOP
    v_ref := to_jsonb(NEW) ->> TG_ARGV[i];
    IF v_ref IS NOT NULL THEN
      EXECUTE format('SELECT org_id FROM public.%I WHERE id = $1', TG_ARGV[i+1]) INTO v_org USING v_ref::uuid;
      IF v_org IS NOT NULL THEN NEW.org_id := v_org; RETURN NEW; END IF;
    END IF;
    i := i + 2;
  END LOOP;
  NEW.org_id := current_org_id();
  RETURN NEW;
END $$;

-- Attach fill_org_id to every tenant table (parents listed in priority order)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('app_roles', ''), ('app_users', ''), ('invitations', ''), ('settings', ''),
    ('lead_sources', ''), ('job_stages', ''), ('appointment_types', ''), ('job_event_types', ''),
    ('pricing_types', ''), ('vendors', ''),
    ('customers', ''),
    ('auth_tokens', '''customer_id'',''customers'''),
    ('libraries', ''),
    ('library_folders', '''library_id'',''libraries'''),
    ('items_catalog', '''library_id'',''libraries'''),
    ('pricing_attributes', ''),
    ('pricing_attribute_options', '''attribute_id'',''pricing_attributes'''),
    ('catalog_item_attributes', '''item_id'',''items_catalog'''),
    ('assemblies', '''library_id'',''libraries'''),
    ('assembly_items', '''assembly_id'',''assemblies'''),
    ('quotes', '''customer_id'',''customers'''),
    ('quote_packages', '''quote_id'',''quotes'''),
    ('quote_package_items', '''package_id'',''quote_packages'''),
    ('quote_line_items', '''quote_id'',''quotes'''),
    ('quote_attachments', '''quote_id'',''quotes'''),
    ('quote_views', '''quote_id'',''quotes'''),
    ('change_orders', '''quote_id'',''quotes'''),
    ('change_order_items', '''change_order_id'',''change_orders'''),
    ('invoices', '''customer_id'',''customers'',''quote_id'',''quotes'''),
    ('invoice_line_items', '''invoice_id'',''invoices'''),
    ('payments', '''invoice_id'',''invoices'',''customer_id'',''customers'''),
    ('payment_allocations', '''payment_id'',''payments'',''invoice_id'',''invoices'''),
    ('payment_schedule_templates', ''),
    ('payment_schedule_template_items', '''template_id'',''payment_schedule_templates'''),
    ('jobs', '''customer_id'',''customers'',''quote_id'',''quotes'''),
    ('job_events', '''job_id'',''jobs'''),
    ('job_photos', '''job_id'',''jobs'''),
    ('punch_list_items', '''job_id'',''jobs'''),
    ('todos', '''job_id'',''jobs'''),
    ('appointments', '''customer_id'',''customers'',''deal_id'',''jobs'''),
    ('customer_uploads', '''customer_id'',''customers'',''quote_id'',''quotes'''),
    ('activity_log', '''customer_id'',''customers'''),
    ('booking_forms', ''),
    ('booking_form_questions', '''form_id'',''booking_forms'''),
    ('booking_submissions', '''form_id'',''booking_forms'',''customer_id'',''customers'''),
    ('email_templates', ''),
    ('email_logs', '''customer_id'',''customers'',''deal_id'',''jobs'',''appointment_id'',''appointments'''),
    ('email_sequences', ''),
    ('sequence_steps', '''sequence_id'',''email_sequences'''),
    ('scheduled_emails', '''deal_id'',''jobs'''),
    ('notification_queue', '''customer_id'',''customers'''),
    ('notifications', '''customer_id'',''customers'''),
    ('coa_categories', ''),
    ('ledger_accounts', ''),
    ('ledger_import_batches', '''account_id'',''ledger_accounts'''),
    ('ledger_rules', '''category_id'',''coa_categories'''),
    ('ledger_transactions', '''account_id'',''ledger_accounts'''),
    ('ledger_splits', '''transaction_id'',''ledger_transactions'''),
    ('google_calendar_connection', ''),
    ('quickbooks_connection', '')
  ) AS t(tbl, args)
  LOOP
    EXECUTE format('CREATE TRIGGER aa_fill_org_id BEFORE INSERT ON public.%I FOR EACH ROW EXECUTE FUNCTION public.fill_org_id(%s)', r.tbl, r.args);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

CREATE TRIGGER trg_ledger_txn_updated BEFORE UPDATE ON public.ledger_transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- DOCUMENT NUMBERING (per organization, atomic)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.next_org_counter(p_key text, p_org uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_num integer;
BEGIN
  IF p_org IS NULL THEN RAISE EXCEPTION 'No organization in context'; END IF;
  INSERT INTO settings (org_id, key, value) VALUES (p_org, p_key, '{"value": 1001}')
  ON CONFLICT (org_id, key) DO NOTHING;
  UPDATE settings SET value = jsonb_set(value, '{value}', to_jsonb(COALESCE((value->>'value')::int, 1001) + 1)),
                      updated_at = now()
   WHERE org_id = p_org AND key = p_key
  RETURNING (value->>'value')::int - 1 INTO v_num;
  RETURN v_num;
END $$;

CREATE OR REPLACE FUNCTION public.generate_quote_number(p_org uuid DEFAULT NULL)
RETURNS varchar LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT 'Q-' || to_char(now(), 'YYYY') || '-' ||
         lpad(next_org_counter('next_quote_number', CASE WHEN auth.uid() IS NULL THEN p_org ELSE current_org_id() END)::text, 4, '0');
$$;

CREATE OR REPLACE FUNCTION public.generate_invoice_number(p_org uuid DEFAULT NULL)
RETURNS varchar LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT 'INV-' || to_char(now(), 'YYYY') || '-' ||
         lpad(next_org_counter('next_invoice_number', CASE WHEN auth.uid() IS NULL THEN p_org ELSE current_org_id() END)::text, 4, '0');
$$;

CREATE OR REPLACE FUNCTION public.generate_job_number(p_org uuid DEFAULT NULL)
RETURNS varchar LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT 'JOB-' || to_char(now(), 'YYYY') || '-' ||
         lpad(next_org_counter('next_job_number', CASE WHEN auth.uid() IS NULL THEN p_org ELSE current_org_id() END)::text, 4, '0');
$$;

CREATE OR REPLACE FUNCTION public.generate_change_order_number(p_org uuid DEFAULT NULL)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT next_org_counter('next_change_order_number', CASE WHEN auth.uid() IS NULL THEN p_org ELSE current_org_id() END)::text;
$$;

-- Only callable for your own org (service role may pass any org)
REVOKE EXECUTE ON FUNCTION public.next_org_counter(text, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- QUOTES / INVOICES / PAYMENTS LOGIC
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.increment_quote_views(quote_uuid uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE quotes SET view_count = COALESCE(view_count, 0) + 1 WHERE id = quote_uuid;
END $$;

CREATE OR REPLACE FUNCTION public.update_quote_totals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  q RECORD;
  s numeric(10,2); s_low numeric(10,2); s_high numeric(10,2);
  has_ranges boolean; dep numeric(10,2);
BEGIN
  SELECT * INTO q FROM quotes WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
  IF q IS NULL THEN RETURN NEW; END IF;
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
CREATE TRIGGER trigger_update_quote_totals AFTER INSERT OR DELETE OR UPDATE ON public.quote_line_items
  FOR EACH ROW EXECUTE FUNCTION update_quote_totals();

CREATE OR REPLACE FUNCTION public.update_invoice_totals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  inv RECORD;
  c_sub numeric(10,2); c_tax_base numeric(10,2); c_disc_base numeric(10,2); c_tax_disc numeric(10,2);
  c_disc numeric(10,2); share numeric; c_tax numeric(10,2); c_total numeric(10,2);
BEGIN
  SELECT * INTO inv FROM invoices WHERE id = COALESCE(NEW.invoice_id, OLD.invoice_id);
  IF inv IS NULL THEN RETURN NEW; END IF;
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
CREATE TRIGGER trigger_update_invoice_totals AFTER INSERT OR DELETE OR UPDATE ON public.invoice_line_items
  FOR EACH ROW EXECUTE FUNCTION update_invoice_totals();

CREATE OR REPLACE FUNCTION public.recalculate_invoice_payments(p_invoice_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE paid numeric(10,2); inv_total numeric(10,2); cur varchar(20);
BEGIN
  IF p_invoice_id IS NULL THEN RETURN; END IF;
  SELECT total, status INTO inv_total, cur FROM invoices WHERE id = p_invoice_id;
  IF inv_total IS NULL THEN RETURN; END IF;
  SELECT COALESCE(SUM(pa.amount),0) INTO paid
    FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id
   WHERE pa.invoice_id = p_invoice_id AND p.status = 'succeeded';
  UPDATE invoices SET
    amount_paid = paid,
    amount_due = inv_total - paid,
    status = CASE WHEN paid >= inv_total AND inv_total > 0 THEN 'paid'
                  WHEN paid > 0 THEN 'partial'
                  WHEN cur IN ('paid','partial') THEN 'sent'
                  ELSE cur END,
    paid_at = CASE WHEN paid >= inv_total AND inv_total > 0 THEN COALESCE(paid_at, now()) END,
    updated_at = now()
  WHERE id = p_invoice_id;
END $$;

CREATE OR REPLACE FUNCTION public.trigger_recalc_invoice_from_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM recalculate_invoice_payments(OLD.invoice_id); RETURN OLD; END IF;
  PERFORM recalculate_invoice_payments(NEW.invoice_id);
  IF TG_OP = 'UPDATE' AND OLD.invoice_id IS DISTINCT FROM NEW.invoice_id THEN
    PERFORM recalculate_invoice_payments(OLD.invoice_id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trigger_payment_allocations_recalc AFTER INSERT OR DELETE OR UPDATE ON public.payment_allocations
  FOR EACH ROW EXECUTE FUNCTION trigger_recalc_invoice_from_allocation();

CREATE OR REPLACE FUNCTION public.sync_payment_to_allocations()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer; inv RECORD;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'succeeded' AND NEW.invoice_id IS NOT NULL THEN
      INSERT INTO payment_allocations (org_id, payment_id, invoice_id, amount)
      VALUES (NEW.org_id, NEW.id, NEW.invoice_id, NEW.amount);
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = 'succeeded' AND OLD.status IS DISTINCT FROM 'succeeded' AND NEW.invoice_id IS NOT NULL THEN
    SELECT COUNT(*) INTO n FROM payment_allocations WHERE payment_id = NEW.id;
    IF n = 0 THEN
      INSERT INTO payment_allocations (org_id, payment_id, invoice_id, amount)
      VALUES (NEW.org_id, NEW.id, NEW.invoice_id, NEW.amount);
    END IF;
  END IF;
  IF OLD.status = 'succeeded' AND NEW.status IS DISTINCT FROM 'succeeded' THEN
    FOR inv IN SELECT DISTINCT invoice_id FROM payment_allocations WHERE payment_id = NEW.id LOOP
      PERFORM recalculate_invoice_payments(inv.invoice_id);
    END LOOP;
  END IF;
  IF NEW.amount IS DISTINCT FROM OLD.amount THEN
    SELECT COUNT(*) INTO n FROM payment_allocations WHERE payment_id = NEW.id;
    IF n = 1 THEN UPDATE payment_allocations SET amount = NEW.amount WHERE payment_id = NEW.id; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trigger_sync_payment_to_allocations AFTER INSERT OR UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION sync_payment_to_allocations();

CREATE OR REPLACE FUNCTION public.link_job_to_invoice()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE jobs SET invoice_id = NULL WHERE invoice_id = OLD.id;
    RETURN OLD;
  END IF;
  IF NEW.quote_id IS NOT NULL THEN
    UPDATE jobs SET invoice_id = NEW.id
     WHERE quote_id = NEW.quote_id AND org_id = NEW.org_id
       AND (invoice_id IS NULL OR invoice_id = NEW.id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_link_job_to_invoice AFTER INSERT OR DELETE OR UPDATE OF quote_id ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION link_job_to_invoice();

CREATE OR REPLACE FUNCTION public.create_job_from_quote()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status <> 'accepted')
     AND NOT EXISTS (SELECT 1 FROM jobs WHERE quote_id = NEW.id) THEN
    INSERT INTO jobs (org_id, job_number, name, customer_id, quote_id, stage, estimated_value, notes)
    VALUES (NEW.org_id, generate_job_number(NEW.org_id), NEW.title, NEW.customer_id, NEW.id,
            CASE WHEN EXISTS (SELECT 1 FROM job_stages WHERE org_id = NEW.org_id AND stage_id = 'job-sold')
                 THEN 'job-sold' ELSE (SELECT stage_id FROM job_stages WHERE org_id = NEW.org_id ORDER BY sort_order LIMIT 1) END,
            NEW.total, 'Created from quote ' || NEW.quote_number);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trigger_create_job_from_quote AFTER UPDATE OF status ON public.quotes
  FOR EACH ROW WHEN (NEW.status = 'accepted') EXECUTE FUNCTION create_job_from_quote();

CREATE OR REPLACE FUNCTION public.update_job_stage(p_job_id uuid, p_new_stage varchar)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE jobs SET stage = p_new_stage, updated_at = now(),
         completed_date = CASE WHEN p_new_stage = 'completed' THEN now() ELSE completed_date END
   WHERE id = p_job_id;
END $$;

-- ---------------------------------------------------------------------
-- ACTIVITY LOG TRIGGERS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_invoice_paid_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO activity_log (org_id, customer_id, activity_type, reference_type, reference_id, description)
  VALUES (NEW.org_id, NEW.customer_id, 'invoice_paid', 'invoice', NEW.id, 'Invoice paid (' || NEW.invoice_number || ')');
  RETURN NEW;
END $$;
CREATE TRIGGER trg_log_invoice_paid_activity AFTER UPDATE OF status ON public.invoices
  FOR EACH ROW WHEN (NEW.status = 'paid' AND OLD.status IS DISTINCT FROM 'paid')
  EXECUTE FUNCTION log_invoice_paid_activity();

CREATE OR REPLACE FUNCTION public.log_payment_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_customer uuid; v_invoice text;
BEGIN
  SELECT COALESCE(NEW.customer_id, i.customer_id), i.invoice_number INTO v_customer, v_invoice
    FROM (SELECT 1) s LEFT JOIN invoices i ON i.id = NEW.invoice_id;
  INSERT INTO activity_log (org_id, customer_id, activity_type, reference_type, reference_id, description)
  VALUES (NEW.org_id, v_customer, 'payment_received', 'payment', NEW.id,
          'Payment of $' || to_char(NEW.amount, 'FM999,999,990.00') ||
          COALESCE(' (' || NEW.payment_method || ')', '') || COALESCE(' on invoice ' || v_invoice, ''));
  RETURN NEW;
END $$;
CREATE TRIGGER trg_log_payment_activity_insert AFTER INSERT ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'succeeded') EXECUTE FUNCTION log_payment_activity();
CREATE TRIGGER trg_log_payment_activity_update AFTER UPDATE OF status ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'succeeded' AND OLD.status IS DISTINCT FROM 'succeeded')
  EXECUTE FUNCTION log_payment_activity();

CREATE OR REPLACE FUNCTION public.log_quote_accepted_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO activity_log (org_id, customer_id, activity_type, reference_type, reference_id, description)
  VALUES (NEW.org_id, NEW.customer_id, 'quote_accepted', 'quote', NEW.id, 'Quote accepted (' || NEW.quote_number || ')');
  RETURN NEW;
END $$;
CREATE TRIGGER trg_log_quote_accepted_activity AFTER UPDATE OF status ON public.quotes
  FOR EACH ROW WHEN (NEW.status = 'accepted' AND OLD.status IS DISTINCT FROM 'accepted')
  EXECUTE FUNCTION log_quote_accepted_activity();

CREATE OR REPLACE FUNCTION public.log_quote_view_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_customer uuid; v_number text;
BEGIN
  SELECT customer_id, quote_number INTO v_customer, v_number FROM quotes WHERE id = NEW.quote_id;
  INSERT INTO activity_log (org_id, customer_id, activity_type, reference_type, reference_id, description, ip_address)
  VALUES (NEW.org_id, v_customer, 'quote_viewed', 'quote', NEW.quote_id,
          'Customer viewed quote' || COALESCE(' (' || v_number || ')', ''), NEW.ip_address);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_log_quote_view_activity AFTER INSERT ON public.quote_views
  FOR EACH ROW EXECUTE FUNCTION log_quote_view_activity();

-- ---------------------------------------------------------------------
-- EMAIL SEQUENCES
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_sequence_send_at(
  p_base timestamptz, p_delay_days int, p_delay_hours int, p_send_time time, p_weekdays_only boolean,
  p_tz text DEFAULT 'America/New_York')
RETURNS timestamptz LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE v_at timestamptz; v_local_date date; tz text := COALESCE(p_tz, 'America/New_York');
BEGIN
  IF p_send_time IS NULL THEN
    v_at := p_base + make_interval(days => p_delay_days, hours => p_delay_hours);
  ELSE
    v_local_date := ((p_base + make_interval(hours => p_delay_hours)) AT TIME ZONE tz)::date + p_delay_days;
    v_at := (v_local_date + p_send_time) AT TIME ZONE tz;
    IF v_at < p_base THEN v_at := ((v_local_date + 1) + p_send_time) AT TIME ZONE tz; END IF;
  END IF;
  IF p_weekdays_only THEN
    WHILE EXTRACT(ISODOW FROM (v_at AT TIME ZONE tz)) IN (6, 7) LOOP
      v_at := ((v_at AT TIME ZONE tz) + interval '1 day') AT TIME ZONE tz;
    END LOOP;
  END IF;
  RETURN v_at;
END $$;

CREATE OR REPLACE FUNCTION public.enroll_deal_in_sequence(p_deal_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_deal RECORD; v_seq RECORD; v_step RECORD;
  v_send_at timestamptz; v_last timestamptz; v_count int := 0; v_tz text;
BEGIN
  SELECT j.id, j.org_id, j.stage, j.customer_id, j.automations_off, c.email,
         COALESCE(c.disable_drips, false) AS disable_drips
    INTO v_deal
    FROM jobs j LEFT JOIN customers c ON c.id = j.customer_id
   WHERE j.id = p_deal_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  -- Callers from the browser may only touch their own org's deals
  IF auth.uid() IS NOT NULL AND v_deal.org_id IS DISTINCT FROM current_org_id() THEN RETURN 0; END IF;

  UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Deal changed stage'
   WHERE deal_id = p_deal_id AND status = 'pending';

  IF v_deal.stage IS NULL OR v_deal.automations_off THEN RETURN 0; END IF;

  SELECT timezone INTO v_tz FROM organizations WHERE id = v_deal.org_id;
  SELECT * INTO v_seq FROM email_sequences
   WHERE org_id = v_deal.org_id AND stage_id = v_deal.stage AND is_active;
  IF NOT FOUND THEN RETURN 0; END IF;

  IF v_deal.email IS NOT NULL AND v_deal.email <> '' AND NOT v_deal.disable_drips THEN
    FOR v_step IN SELECT * FROM sequence_steps WHERE sequence_id = v_seq.id AND is_active
                  ORDER BY step_order, created_at LOOP
      v_send_at := compute_sequence_send_at(now(), v_step.delay_days, v_step.delay_hours,
                                            v_step.send_time, v_step.weekdays_only, v_tz);
      INSERT INTO scheduled_emails (org_id, kind, sequence_id, step_id, deal_id, customer_id, stage_id, send_at)
      VALUES (v_deal.org_id, 'email', v_seq.id, v_step.id, v_deal.id, v_deal.customer_id, v_deal.stage, v_send_at);
      v_last := GREATEST(COALESCE(v_last, v_send_at), v_send_at);
      v_count := v_count + 1;
    END LOOP;
  END IF;

  IF v_seq.advance_to_stage IS NOT NULL AND v_seq.advance_to_stage <> v_deal.stage THEN
    INSERT INTO scheduled_emails (org_id, kind, sequence_id, deal_id, customer_id, stage_id, advance_to_stage, send_at)
    VALUES (v_deal.org_id, 'advance', v_seq.id, v_deal.id, v_deal.customer_id, v_deal.stage, v_seq.advance_to_stage,
            COALESCE(v_last, now()) + make_interval(days => v_seq.advance_after_days));
  END IF;
  RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION public.trg_jobs_enroll_sequence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.automations_off AND NOT OLD.automations_off THEN
    UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Automations turned off for this deal'
     WHERE deal_id = NEW.id AND status = 'pending';
  END IF;
  IF TG_OP = 'INSERT' OR NEW.stage IS DISTINCT FROM OLD.stage THEN
    BEGIN
      PERFORM enroll_deal_in_sequence(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enroll_deal_in_sequence failed for deal %: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_jobs_enroll_sequence AFTER INSERT OR UPDATE OF stage, automations_off ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION trg_jobs_enroll_sequence();

CREATE OR REPLACE FUNCTION public.trg_customers_cancel_drips()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.disable_drips = true AND COALESCE(OLD.disable_drips, false) = false THEN
    UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Customer opted out'
     WHERE customer_id = NEW.id AND status = 'pending' AND kind = 'email';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_customers_cancel_drips AFTER UPDATE OF disable_drips ON public.customers
  FOR EACH ROW EXECUTE FUNCTION trg_customers_cancel_drips();

CREATE OR REPLACE FUNCTION public.trg_email_sequences_cancel_pending()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.is_active = false AND OLD.is_active = true THEN
    UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Sequence turned off'
     WHERE sequence_id = NEW.id AND status = 'pending';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_email_sequences_cancel_pending AFTER UPDATE OF is_active ON public.email_sequences
  FOR EACH ROW EXECUTE FUNCTION trg_email_sequences_cancel_pending();

CREATE OR REPLACE FUNCTION public.trg_sequence_steps_cancel_pending()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Email removed from sequence'
     WHERE step_id = OLD.id AND status = 'pending';
    RETURN OLD;
  END IF;
  IF NEW.is_active = false AND OLD.is_active = true THEN
    UPDATE scheduled_emails SET status = 'cancelled', status_reason = 'Email turned off'
     WHERE step_id = NEW.id AND status = 'pending';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sequence_steps_cancel_pending BEFORE DELETE OR UPDATE OF is_active ON public.sequence_steps
  FOR EACH ROW EXECUTE FUNCTION trg_sequence_steps_cancel_pending();

-- ---------------------------------------------------------------------
-- VIEWS (security_invoker so tenant RLS applies)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.job_pipeline_summary WITH (security_invoker = true) AS
SELECT js.org_id, js.stage_id, js.label, js.color, js.sort_order,
       count(j.id) AS job_count, COALESCE(sum(j.estimated_value), 0) AS total_value
  FROM job_stages js
  LEFT JOIN jobs j ON j.org_id = js.org_id AND j.stage = js.stage_id
 WHERE js.is_active
 GROUP BY js.id, js.org_id, js.stage_id, js.label, js.color, js.sort_order
 ORDER BY js.sort_order;

CREATE OR REPLACE VIEW public.jobs_with_details WITH (security_invoker = true) AS
SELECT j.id, j.org_id, j.job_number, j.name, j.customer_id, j.quote_id, j.invoice_id, j.stage,
       j.shop_date, j.installation_date, j.completed_date, j.job_items, j.colors, j.refacing_materials,
       j.estimated_value, j.actual_value, j.notes, j.internal_notes, j.created_at, j.updated_at,
       j.assigned_to, j.project_manager_id, j.job_street, j.job_city, j.job_state, j.job_zip,
       c.name AS customer_name, c.first_name AS customer_first_name, c.last_name AS customer_last_name,
       c.email AS customer_email, c.phone AS customer_phone, c.address AS customer_address,
       c.city AS customer_city, c.state AS customer_state, c.zip AS customer_zip,
       q.quote_number, q.total AS quote_total, js.label AS stage_label, js.color AS stage_color,
       au.name AS assigned_to_name, pm.name AS project_manager_name
  FROM jobs j
  LEFT JOIN customers c ON j.customer_id = c.id
  LEFT JOIN quotes q ON j.quote_id = q.id
  LEFT JOIN job_stages js ON js.org_id = j.org_id AND js.stage_id = j.stage
  LEFT JOIN app_users au ON j.assigned_to = au.id
  LEFT JOIN app_users pm ON j.project_manager_id = pm.id;

CREATE OR REPLACE VIEW public.ledger_account_balances WITH (security_invoker = true) AS
SELECT a.id, a.org_id,
       a.opening_balance + COALESCE(sum(t.amount), 0) AS balance,
       count(t.id) FILTER (WHERE t.status = 'uncategorized') AS uncategorized_count,
       max(t.txn_date) AS last_txn_date
  FROM ledger_accounts a
  LEFT JOIN ledger_transactions t ON t.account_id = a.id AND t.status <> 'excluded'
 GROUP BY a.id, a.org_id, a.opening_balance;
