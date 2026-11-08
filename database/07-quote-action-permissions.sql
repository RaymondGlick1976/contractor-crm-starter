-- =====================================================================
-- YOURCRM — part 7: quote action permissions
-- Splits "Accept" and "Convert to Invoice" out of Edit Quotes.
-- Carried over from the original single-business app; adapted for per-org roles.
-- =====================================================================
SET search_path = public, extensions;

ALTER TABLE public.app_roles
  ADD COLUMN IF NOT EXISTS can_accept_quotes  boolean DEFAULT true,
  ADD COLUMN IF NOT EXISTS can_convert_quotes boolean DEFAULT true;

-- Roles that couldn't edit quotes shouldn't accept/convert them either
UPDATE public.app_roles
   SET can_accept_quotes = false, can_convert_quotes = false
 WHERE can_edit_quotes = false;

-- Default "Sales" role: can accept a quote, but converting to an invoice
-- is an invoicing action and Sales has no invoice access.
UPDATE public.app_roles
   SET can_convert_quotes = false
 WHERE is_system = true AND name = 'Sales';

-- seed_org_defaults() is redefined in 03-security-onboarding.sql to
-- include the new columns; re-run that file (or just the function) after this.
