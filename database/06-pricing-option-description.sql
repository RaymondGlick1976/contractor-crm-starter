-- =====================================================================
-- YOURCRM — part 6: description on pricing attribute options
-- Optional free-text shown under the option name on the Pricing
-- Attributes page (what's included, notes for quotes, etc.).
-- Carried over from the original single-business app.
-- =====================================================================
SET search_path = public, extensions;

ALTER TABLE public.pricing_attribute_options
  ADD COLUMN IF NOT EXISTS description text;
