-- =====================================================================
-- YOURCRM — MULTI-TENANT SCHEMA (part 1: tables)
-- Multi-tenant schema.
-- Every business-owned table carries org_id → organizations(id).
-- org_id is filled automatically by the fill_org_id() trigger (03-functions.sql)
-- from the parent row or from the signed-in user's active organization.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- TENANCY CORE
-- ---------------------------------------------------------------------
CREATE TABLE public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL UNIQUE,
  timezone text NOT NULL DEFAULT 'America/New_York',
  plan text NOT NULL DEFAULT 'trial',
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text,
  active_org_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
  is_platform_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- ROLES & STAFF (app_users is the org membership table)
-- ---------------------------------------------------------------------
CREATE TABLE public.app_roles (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  description text,
  can_access_settings boolean DEFAULT false,
  can_view_financials boolean DEFAULT false,
  can_delete boolean DEFAULT false,
  can_manage_users boolean DEFAULT false,
  can_send_invoices boolean DEFAULT false,
  can_edit_quotes boolean DEFAULT true,
  can_edit_customers boolean DEFAULT true,
  can_edit_pipeline boolean DEFAULT true,
  is_system boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  can_view_quotes boolean DEFAULT true,
  can_view_invoices boolean DEFAULT true,
  can_view_customers boolean DEFAULT true,
  can_view_pipeline boolean DEFAULT true,
  can_accept_quotes boolean DEFAULT true,
  can_convert_quotes boolean DEFAULT true,
  UNIQUE (org_id, name)
);

CREATE TABLE public.app_users (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  name varchar(100) NOT NULL,
  pin varchar(20),
  role_id uuid REFERENCES public.app_roles(id) ON DELETE SET NULL,
  is_active boolean DEFAULT true,
  last_login timestamptz,
  created_at timestamptz DEFAULT now(),
  UNIQUE (org_id, user_id)
);
CREATE INDEX idx_app_users_user ON public.app_users(user_id);

CREATE TABLE public.invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  email text NOT NULL,
  name text,
  role_id uuid REFERENCES public.app_roles(id) ON DELETE SET NULL,
  token uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  invited_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '14 days',
  accepted_at timestamptz,
  revoked_at timestamptz
);
CREATE INDEX idx_invitations_org ON public.invitations(org_id);

-- ---------------------------------------------------------------------
-- SETTINGS & LOOKUPS
-- ---------------------------------------------------------------------
CREATE TABLE public.settings (
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  key varchar(100) NOT NULL,
  value jsonb NOT NULL,
  updated_at timestamptz DEFAULT now(),
  PRIMARY KEY (org_id, key)
);

CREATE TABLE public.lead_sources (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE (org_id, name)
);

CREATE TABLE public.job_stages (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stage_id varchar(50) NOT NULL,
  label varchar(100) NOT NULL,
  color varchar(20) DEFAULT '#6366f1',
  sort_order integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  UNIQUE (org_id, stage_id)
);

CREATE TABLE public.appointment_types (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  color varchar(20) DEFAULT '#6366f1',
  icon varchar(10) DEFAULT '📅',
  sort_order integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.job_event_types (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  color varchar(20) DEFAULT '#6366f1',
  icon varchar(10) DEFAULT '📅',
  sort_order integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.pricing_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code varchar(50) NOT NULL,
  name varchar(100) NOT NULL,
  label varchar(50) NOT NULL,
  is_builtin boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE (org_id, code)
);

CREATE TABLE public.vendors (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  contact_name varchar(255),
  phone varchar(50),
  email varchar(255),
  address text,
  city varchar(100),
  state varchar(50),
  zip varchar(20),
  website text,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------
-- CUSTOMERS
-- ---------------------------------------------------------------------
CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  email varchar(255) NOT NULL,
  phone varchar(50),
  address text,
  city varchar(100),
  state varchar(50),
  zip varchar(20),
  notes text,
  portal_token uuid DEFAULT uuid_generate_v4(),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  last_login_at timestamptz,
  lead_source varchar(100),
  company varchar(255),
  first_name varchar(100),
  last_name varchar(100),
  lead_source_id uuid REFERENCES public.lead_sources(id) ON DELETE SET NULL,
  assigned_to uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  disable_drips boolean DEFAULT false,
  qb_customer_id varchar(50),
  unsubscribe_token uuid DEFAULT gen_random_uuid(),
  UNIQUE (org_id, email)
);
CREATE INDEX idx_customers_org ON public.customers(org_id);
CREATE INDEX idx_customers_email ON public.customers(email);
CREATE INDEX idx_customers_assigned_to ON public.customers(assigned_to);
CREATE INDEX idx_customers_lead_source_id ON public.customers(lead_source_id);
CREATE INDEX idx_customers_portal_token ON public.customers(portal_token);
CREATE UNIQUE INDEX idx_customers_unsubscribe_token ON public.customers(unsubscribe_token);

CREATE TABLE public.auth_tokens (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  token uuid NOT NULL DEFAULT uuid_generate_v4() UNIQUE,
  token_type varchar(20) NOT NULL CHECK (token_type IN ('magic_link','session')),
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  ip_address varchar(50),
  user_agent text
);
CREATE INDEX idx_auth_tokens_customer ON public.auth_tokens(customer_id);

-- ---------------------------------------------------------------------
-- CATALOG
-- ---------------------------------------------------------------------
CREATE TABLE public.libraries (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  is_default boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.library_folders (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  library_id uuid NOT NULL REFERENCES public.libraries(id) ON DELETE CASCADE,
  parent_id uuid REFERENCES public.library_folders(id) ON DELETE CASCADE,
  name text NOT NULL,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX idx_library_folders_library ON public.library_folders(library_id);

CREATE TABLE public.items_catalog (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  description text,
  category varchar(100),
  default_price numeric(10,2),
  price_range_low numeric(10,2),
  price_range_high numeric(10,2),
  photo_url text,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  is_taxable boolean DEFAULT true,
  library_id uuid REFERENCES public.libraries(id) ON DELETE SET NULL,
  folder_id uuid REFERENCES public.library_folders(id) ON DELETE SET NULL,
  item_number varchar(50),
  notes text,
  vendor_id uuid REFERENCES public.vendors(id) ON DELETE SET NULL,
  product_sku varchar(100),
  cost_price numeric(10,2),
  selling_price numeric(10,2),
  cost numeric,
  markup_percentage numeric,
  apply_discount boolean DEFAULT true
);
CREATE INDEX idx_items_catalog_org ON public.items_catalog(org_id);
CREATE INDEX idx_items_catalog_library ON public.items_catalog(library_id);
CREATE INDEX idx_items_catalog_folder ON public.items_catalog(folder_id);

CREATE TABLE public.pricing_attributes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  is_public boolean DEFAULT false,
  default_markup_percentage numeric
);

CREATE TABLE public.pricing_attribute_options (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  attribute_id uuid REFERENCES public.pricing_attributes(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  flat_adjustment numeric(10,2) DEFAULT 0,
  multiplier numeric(10,4) DEFAULT 1,
  is_default boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  pricing_type text DEFAULT 'each',
  unit_price numeric(10,2) DEFAULT 0,
  cost numeric,
  markup_percentage numeric
);
CREATE INDEX idx_pricing_attribute_options_attribute ON public.pricing_attribute_options(attribute_id);

CREATE TABLE public.catalog_item_attributes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  item_id uuid REFERENCES public.items_catalog(id) ON DELETE CASCADE,
  attribute_id uuid REFERENCES public.pricing_attributes(id) ON DELETE CASCADE,
  is_required boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  pricing_type text NOT NULL DEFAULT 'each' CHECK (pricing_type IN ('each','sqft')),
  UNIQUE (item_id, attribute_id)
);

CREATE TABLE public.assemblies (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  library_id uuid NOT NULL REFERENCES public.libraries(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.assembly_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  assembly_id uuid NOT NULL REFERENCES public.assemblies(id) ON DELETE CASCADE,
  catalog_item_id uuid NOT NULL REFERENCES public.items_catalog(id) ON DELETE CASCADE,
  quantity numeric(10,2) DEFAULT 1,
  sort_order integer DEFAULT 0,
  UNIQUE (assembly_id, catalog_item_id)
);

-- ---------------------------------------------------------------------
-- QUOTES
-- ---------------------------------------------------------------------
CREATE TABLE public.quotes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_number varchar(50) NOT NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  title varchar(255) NOT NULL,
  description text,
  status varchar(20) DEFAULT 'draft' CHECK (status IN ('draft','pending','sent','viewed','accepted','declined','expired','converted','archived')),
  quote_type varchar(20) DEFAULT 'final' CHECK (quote_type IN ('ballpark','final')),
  subtotal numeric(10,2) DEFAULT 0,
  subtotal_low numeric(10,2),
  subtotal_high numeric(10,2),
  tax_rate numeric(5,4) DEFAULT 0,
  tax_amount numeric(10,2) DEFAULT 0,
  total numeric(10,2) DEFAULT 0,
  total_low numeric(10,2),
  total_high numeric(10,2),
  deposit_type varchar(20) DEFAULT 'percentage' CHECK (deposit_type IN ('percentage','fixed')),
  deposit_value numeric(10,2) DEFAULT 50,
  deposit_amount numeric(10,2),
  video_url text,
  notes text,
  internal_notes text,
  valid_days integer DEFAULT 30,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  sent_at timestamptz,
  viewed_at timestamptz,
  accepted_at timestamptz,
  expires_at timestamptz,
  access_token varchar(64) UNIQUE,
  packages_enabled boolean DEFAULT false,
  selected_package_id uuid,
  slider_settings jsonb,
  payment_method varchar(50),
  payment_schedule jsonb,
  terms_and_conditions text,
  qb_estimate_id varchar(50),
  qb_synced_at timestamptz,
  discount_type varchar DEFAULT 'percentage',
  discount_value numeric DEFAULT 0,
  discount_amount numeric DEFAULT 0,
  footer_button_ids jsonb,
  view_count integer DEFAULT 0,
  UNIQUE (org_id, quote_number)
);
CREATE INDEX idx_quotes_org ON public.quotes(org_id);
CREATE INDEX idx_quotes_customer ON public.quotes(customer_id);
CREATE INDEX idx_quotes_status ON public.quotes(status);

CREATE TABLE public.quote_packages (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_id uuid NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  description text,
  price numeric(10,2),
  is_recommended boolean DEFAULT false,
  is_selected boolean DEFAULT false,
  apply_tax boolean DEFAULT false,
  tax_rate numeric(5,3) DEFAULT 0,
  hide_non_included boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
CREATE INDEX idx_quote_packages_quote_id ON public.quote_packages(quote_id);
ALTER TABLE public.quotes ADD CONSTRAINT quotes_selected_package_id_fkey
  FOREIGN KEY (selected_package_id) REFERENCES public.quote_packages(id) ON DELETE SET NULL;

CREATE TABLE public.quote_package_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  package_id uuid NOT NULL REFERENCES public.quote_packages(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  description text,
  quantity numeric(10,2) DEFAULT 1,
  price numeric(10,2) DEFAULT 0,
  is_included boolean DEFAULT true,
  show_price boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  base_price numeric(10,2) DEFAULT 0,
  attribute_selections jsonb DEFAULT '[]'
);
CREATE INDEX idx_quote_package_items_package_id ON public.quote_package_items(package_id);

CREATE TABLE public.quote_line_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
  catalog_item_id uuid REFERENCES public.items_catalog(id) ON DELETE SET NULL,
  description text NOT NULL,
  details text,
  quantity numeric(10,2) DEFAULT 1,
  unit varchar(50) DEFAULT 'each',
  unit_price numeric(10,2),
  price_range_low numeric(10,2),
  price_range_high numeric(10,2),
  is_range_pricing boolean DEFAULT false,
  line_total numeric(10,2),
  line_total_low numeric(10,2),
  line_total_high numeric(10,2),
  photo_url text,
  is_optional boolean DEFAULT false,
  is_selected boolean DEFAULT false,
  is_taxable boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  attribute_selections jsonb DEFAULT '[]',
  base_price numeric,
  apply_discount boolean DEFAULT true
);
CREATE INDEX idx_quote_line_items_quote ON public.quote_line_items(quote_id);

CREATE TABLE public.quote_attachments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
  file_url text NOT NULL,
  file_name varchar(255) NOT NULL,
  file_type varchar(100),
  file_size integer,
  display_order integer DEFAULT 0,
  uploaded_at timestamptz DEFAULT now()
);
CREATE INDEX idx_quote_attachments_quote ON public.quote_attachments(quote_id);

CREATE TABLE public.quote_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_id uuid NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  viewed_at timestamptz DEFAULT now(),
  ip_address varchar(50),
  user_agent text,
  source varchar(20) DEFAULT 'public'
);
CREATE INDEX idx_quote_views_quote_id ON public.quote_views(quote_id);

CREATE TABLE public.change_orders (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE CASCADE,
  change_order_number varchar(20) NOT NULL,
  title varchar(255),
  status varchar(20) DEFAULT 'draft' CHECK (status IN ('draft','sent','viewed','accepted','declined')),
  subtotal numeric(10,2) DEFAULT 0,
  tax numeric(10,2) DEFAULT 0,
  total numeric(10,2) DEFAULT 0,
  notes text,
  sent_at timestamptz,
  viewed_at timestamptz,
  accepted_at timestamptz,
  declined_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
CREATE INDEX idx_change_orders_quote ON public.change_orders(quote_id);

CREATE TABLE public.change_order_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  change_order_id uuid REFERENCES public.change_orders(id) ON DELETE CASCADE,
  description text NOT NULL,
  quantity numeric(10,2) DEFAULT 1,
  unit_price numeric(10,2) DEFAULT 0,
  total numeric(10,2) DEFAULT 0,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------
-- INVOICES & PAYMENTS
-- ---------------------------------------------------------------------
CREATE TABLE public.invoices (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_number varchar(50) NOT NULL,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE SET NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  title varchar(255) NOT NULL,
  status varchar(20) DEFAULT 'draft' CHECK (status IN ('draft','sent','viewed','partial','paid','overdue','cancelled','archived')),
  subtotal numeric(10,2) DEFAULT 0,
  tax_rate numeric(5,4) DEFAULT 0,
  tax_amount numeric(10,2) DEFAULT 0,
  total numeric(10,2) DEFAULT 0,
  amount_paid numeric(10,2) DEFAULT 0,
  amount_due numeric(10,2) DEFAULT 0,
  notes text,
  internal_notes text,
  due_date date,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  sent_at timestamptz,
  paid_at timestamptz,
  qb_invoice_id varchar(50),
  qb_synced_at timestamptz,
  access_token varchar(64) UNIQUE,
  discount_type varchar DEFAULT 'percentage',
  discount_value numeric DEFAULT 0,
  discount_amount numeric DEFAULT 0,
  payment_schedule jsonb,
  UNIQUE (org_id, invoice_number)
);
CREATE INDEX idx_invoices_org ON public.invoices(org_id);
CREATE INDEX idx_invoices_customer ON public.invoices(customer_id);
CREATE INDEX idx_invoices_quote ON public.invoices(quote_id);

CREATE TABLE public.invoice_line_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id uuid REFERENCES public.invoices(id) ON DELETE CASCADE,
  description text NOT NULL,
  details text,
  quantity numeric(10,2) DEFAULT 1,
  unit varchar(50) DEFAULT 'each',
  unit_price numeric(10,2) NOT NULL,
  line_total numeric(10,2) NOT NULL,
  is_taxable boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  attribute_selections jsonb DEFAULT '[]',
  apply_discount boolean DEFAULT true,
  change_order_id uuid REFERENCES public.change_orders(id) ON DELETE SET NULL
);
CREATE INDEX idx_invoice_line_items_invoice ON public.invoice_line_items(invoice_id);

CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id uuid REFERENCES public.invoices(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  amount numeric(10,2) NOT NULL,
  payment_type varchar(50) DEFAULT 'card' CHECK (payment_type IN ('card','cash','check','other','deposit','progress','final')),
  payment_method varchar(100),
  stripe_payment_intent_id varchar(255),
  stripe_charge_id varchar(255),
  status varchar(20) DEFAULT 'pending' CHECK (status IN ('pending','processing','succeeded','failed','refunded')),
  notes text,
  payment_date timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now(),
  reference_number varchar(100),
  qb_payment_id varchar(50),
  qb_synced_at timestamptz
);
CREATE INDEX idx_payments_org ON public.payments(org_id);
CREATE INDEX idx_payments_invoice ON public.payments(invoice_id);
CREATE INDEX idx_payments_customer ON public.payments(customer_id);
CREATE INDEX idx_payments_stripe ON public.payments(stripe_payment_intent_id);

CREATE TABLE public.payment_allocations (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  payment_id uuid NOT NULL REFERENCES public.payments(id) ON DELETE CASCADE,
  invoice_id uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  amount numeric(10,2) NOT NULL CHECK (amount > 0),
  created_at timestamptz DEFAULT now()
);
CREATE INDEX idx_payment_allocations_invoice ON public.payment_allocations(invoice_id);
CREATE INDEX idx_payment_allocations_payment ON public.payment_allocations(payment_id);

CREATE TABLE public.payment_schedule_templates (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  is_default boolean DEFAULT false,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.payment_schedule_template_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  template_id uuid REFERENCES public.payment_schedule_templates(id) ON DELETE CASCADE,
  name text NOT NULL,
  due_description text,
  amount_type text NOT NULL CHECK (amount_type IN ('percentage','fixed')),
  amount_value numeric(10,2) NOT NULL,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------
-- PIPELINE / JOBS
-- ---------------------------------------------------------------------
CREATE TABLE public.jobs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  job_number varchar(50),
  name varchar(255) NOT NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE SET NULL,
  invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  stage varchar(50) DEFAULT 'new-lead',
  shop_date date,
  installation_date date,
  completed_date date,
  job_items jsonb DEFAULT '[]',
  colors jsonb DEFAULT '[]',
  refacing_materials text,
  estimated_value numeric(10,2),
  actual_value numeric(10,2),
  notes text,
  internal_notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  assigned_to uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  project_manager_id uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  job_street varchar(255),
  job_city varchar(100),
  job_state varchar(50),
  job_zip varchar(20),
  job_finishes jsonb DEFAULT '[]',
  automations_off boolean NOT NULL DEFAULT false,
  UNIQUE (org_id, job_number),
  FOREIGN KEY (org_id, stage) REFERENCES public.job_stages(org_id, stage_id)
);
CREATE INDEX idx_jobs_org ON public.jobs(org_id);
CREATE INDEX idx_jobs_customer ON public.jobs(customer_id);
CREATE INDEX idx_jobs_quote ON public.jobs(quote_id);
CREATE INDEX idx_jobs_stage ON public.jobs(org_id, stage);

CREATE TABLE public.job_events (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  job_id uuid REFERENCES public.jobs(id) ON DELETE CASCADE,
  event_type_id uuid REFERENCES public.job_event_types(id) ON DELETE CASCADE,
  event_date date NOT NULL,
  notes text,
  is_completed boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  event_end_date date,
  event_name text,
  event_color varchar(20)
);
CREATE INDEX idx_job_events_job ON public.job_events(job_id);
CREATE INDEX idx_job_events_date ON public.job_events(event_date);

CREATE TABLE public.job_photos (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  job_id uuid REFERENCES public.jobs(id) ON DELETE CASCADE,
  name varchar(255),
  file_url text,
  file_data text,
  photo_type varchar(50) DEFAULT 'progress',
  notes text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.punch_list_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  description text NOT NULL,
  is_completed boolean DEFAULT false,
  completed_at timestamptz,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX idx_punch_list_job ON public.punch_list_items(job_id);

CREATE TABLE public.todos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  title text NOT NULL,
  notes text,
  bucket text NOT NULL DEFAULT 'today' CHECK (bucket IN ('today','week','later')),
  job_id uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  owner text,
  due_date date,
  is_done boolean NOT NULL DEFAULT false,
  done_at timestamptz,
  source text NOT NULL DEFAULT 'manual',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  external_key text,
  UNIQUE (org_id, external_key)
);

CREATE TABLE public.appointments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  appointment_type_id uuid REFERENCES public.appointment_types(id) ON DELETE SET NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  deal_id uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  title varchar(255) NOT NULL,
  appointment_date date NOT NULL,
  appointment_time time,
  duration_minutes integer DEFAULT 60,
  location text,
  notes text,
  status varchar(20) DEFAULT 'scheduled' CHECK (status IN ('scheduled','completed','cancelled','no-show')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  gcal_event_id text,
  reminder_sent_at timestamptz,
  confirmation_email_sent_at timestamptz
);
CREATE INDEX idx_appointments_org_date ON public.appointments(org_id, appointment_date);

CREATE TABLE public.customer_uploads (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES public.quotes(id) ON DELETE SET NULL,
  file_url text NOT NULL,
  file_name varchar(255) NOT NULL,
  file_type varchar(100),
  file_size integer,
  caption text,
  uploaded_at timestamptz DEFAULT now(),
  job_id uuid
);
CREATE INDEX idx_customer_uploads_customer ON public.customer_uploads(customer_id);

CREATE TABLE public.activity_log (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  activity_type varchar(50) NOT NULL,
  reference_type varchar(50),
  reference_id uuid,
  description text,
  ip_address varchar(50),
  created_at timestamptz DEFAULT now()
);
CREATE INDEX idx_activity_log_org_created ON public.activity_log(org_id, created_at DESC);
CREATE INDEX idx_activity_log_customer ON public.activity_log(customer_id);

-- ---------------------------------------------------------------------
-- BOOKING FORMS (public lead capture)
-- ---------------------------------------------------------------------
CREATE TABLE public.booking_forms (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(100) NOT NULL,
  slug varchar(100) NOT NULL UNIQUE,
  header_title varchar(255) DEFAULT 'Request an Appointment',
  header_description text,
  show_address boolean DEFAULT true,
  show_service_details boolean DEFAULT true,
  show_how_heard boolean DEFAULT true,
  show_date_time boolean DEFAULT false,
  allow_attachments boolean DEFAULT true,
  attachments_required boolean DEFAULT false,
  show_sms_consent boolean DEFAULT true,
  primary_color varchar(20) DEFAULT '#3e855f',
  how_heard_options jsonb DEFAULT '["Google Search","Facebook","Referral","Repeat Customer","Other"]',
  thank_you_title varchar(255) DEFAULT 'Thank You!',
  thank_you_message text DEFAULT 'We have received your request and will be in touch shortly.',
  default_stage varchar(50) DEFAULT 'new-lead',
  is_active boolean DEFAULT true,
  submission_count integer DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  show_scheduler boolean DEFAULT false,
  thank_you_redirect_url text,
  attachments_label varchar(255) DEFAULT 'Please add a few photos of your project'
);

CREATE TABLE public.booking_form_questions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  form_id uuid REFERENCES public.booking_forms(id) ON DELETE CASCADE,
  prompt varchar(255) NOT NULL,
  field_type varchar(20) DEFAULT 'text' CHECK (field_type IN ('text','textarea','dropdown','checkbox','radio')),
  choices jsonb,
  is_required boolean DEFAULT false,
  sort_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.booking_submissions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  form_id uuid REFERENCES public.booking_forms(id) ON DELETE SET NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  deal_id uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  first_name varchar(100) NOT NULL,
  last_name varchar(100) NOT NULL,
  email varchar(255) NOT NULL,
  phone varchar(50),
  address text,
  city varchar(100),
  state varchar(50),
  zip varchar(20),
  service_details text,
  how_heard varchar(100),
  preferred_date date,
  preferred_time time,
  sms_consent boolean DEFAULT false,
  custom_answers jsonb,
  attachments jsonb,
  status varchar(20) DEFAULT 'new' CHECK (status IN ('new','contacted','converted','closed')),
  notes text,
  created_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------
-- EMAIL: templates, logs, sequences
-- ---------------------------------------------------------------------
CREATE TABLE public.email_templates (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name varchar(255) NOT NULL,
  subject varchar(500) NOT NULL,
  body text NOT NULL,
  template_type varchar(50) NOT NULL CHECK (template_type IN ('deal_stage','appointment','quote','invoice','payment','general')),
  stage_id varchar(50),
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  FOREIGN KEY (org_id, stage_id) REFERENCES public.job_stages(org_id, stage_id) ON DELETE SET NULL (stage_id)
);

CREATE TABLE public.email_logs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  template_id uuid REFERENCES public.email_templates(id) ON DELETE SET NULL,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  deal_id uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  appointment_id uuid REFERENCES public.appointments(id) ON DELETE SET NULL,
  to_email varchar(255) NOT NULL,
  subject varchar(500) NOT NULL,
  body text NOT NULL,
  sent_at timestamptz DEFAULT now(),
  sent_by uuid REFERENCES public.app_users(id) ON DELETE SET NULL,
  status varchar(20) DEFAULT 'sent',
  error_message text,
  attempt_count integer DEFAULT 1,
  email_type varchar(50)
);
CREATE INDEX idx_email_logs_customer ON public.email_logs(customer_id);
CREATE INDEX idx_email_logs_deal ON public.email_logs(deal_id);
CREATE INDEX idx_email_logs_retry ON public.email_logs(status, attempt_count) WHERE status = 'failed' AND attempt_count < 3;

CREATE TABLE public.email_sequences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stage_id varchar(50) NOT NULL,
  name varchar(255) NOT NULL,
  is_active boolean NOT NULL DEFAULT false,
  advance_to_stage varchar(50),
  advance_after_days integer NOT NULL DEFAULT 1 CHECK (advance_after_days >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, stage_id),
  FOREIGN KEY (org_id, stage_id) REFERENCES public.job_stages(org_id, stage_id) ON DELETE CASCADE,
  FOREIGN KEY (org_id, advance_to_stage) REFERENCES public.job_stages(org_id, stage_id) ON DELETE SET NULL (advance_to_stage)
);

CREATE TABLE public.sequence_steps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  sequence_id uuid NOT NULL REFERENCES public.email_sequences(id) ON DELETE CASCADE,
  step_order integer NOT NULL DEFAULT 0,
  name varchar(255),
  subject varchar(500) NOT NULL DEFAULT '',
  preheader varchar(255),
  style varchar(20) NOT NULL DEFAULT 'branded' CHECK (style IN ('branded','plain')),
  blocks jsonb NOT NULL DEFAULT '[]',
  delay_days integer NOT NULL DEFAULT 0 CHECK (delay_days >= 0),
  delay_hours integer NOT NULL DEFAULT 0 CHECK (delay_hours >= 0),
  send_time time,
  weekdays_only boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sequence_steps_sequence ON public.sequence_steps(sequence_id, step_order);

CREATE TABLE public.scheduled_emails (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  kind varchar(20) NOT NULL DEFAULT 'email' CHECK (kind IN ('email','advance')),
  sequence_id uuid REFERENCES public.email_sequences(id) ON DELETE SET NULL,
  step_id uuid REFERENCES public.sequence_steps(id) ON DELETE SET NULL,
  deal_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  stage_id varchar(50) NOT NULL,
  advance_to_stage varchar(50),
  send_at timestamptz NOT NULL,
  status varchar(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sending','sent','cancelled','failed','skipped')),
  status_reason text,
  sent_at timestamptz,
  email_log_id uuid REFERENCES public.email_logs(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_scheduled_emails_deal ON public.scheduled_emails(deal_id);
CREATE INDEX idx_scheduled_emails_due ON public.scheduled_emails(send_at) WHERE status = 'pending';

CREATE TABLE public.notification_queue (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  notification_type varchar(50) NOT NULL,
  reference_type varchar(50),
  reference_id uuid,
  scheduled_for timestamptz DEFAULT now(),
  is_admin_notification boolean DEFAULT false,
  sent_at timestamptz,
  error_message text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  customer_id uuid REFERENCES public.customers(id) ON DELETE CASCADE,
  notification_type varchar(50) NOT NULL,
  reference_type varchar(50),
  reference_id uuid,
  subject varchar(255),
  body_html text,
  sent_at timestamptz,
  opened_at timestamptz,
  clicked_at timestamptz,
  created_at timestamptz DEFAULT now()
);

-- ---------------------------------------------------------------------
-- BANKING / LEDGER
-- ---------------------------------------------------------------------
CREATE TABLE public.coa_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  cat_type text NOT NULL CHECK (cat_type IN ('income','cogs','expense','transfer','equity','liability','uncategorized')),
  schedule_c_line text,
  system_key text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, system_key)
);

CREATE TABLE public.ledger_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  account_type text NOT NULL CHECK (account_type IN ('checking','savings','credit_card','cash')),
  institution text,
  last4 text,
  opening_balance numeric NOT NULL DEFAULT 0,
  opening_date date NOT NULL DEFAULT CURRENT_DATE,
  csv_mapping jsonb,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.ledger_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.ledger_accounts(id) ON DELETE CASCADE,
  filename text,
  row_count integer NOT NULL DEFAULT 0,
  imported_count integer NOT NULL DEFAULT 0,
  duplicate_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.ledger_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  match_text text NOT NULL,
  category_id uuid NOT NULL REFERENCES public.coa_categories(id),
  rename_payee text,
  priority integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.ledger_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.ledger_accounts(id) ON DELETE CASCADE,
  txn_date date NOT NULL,
  description text NOT NULL,
  payee text,
  amount numeric NOT NULL,
  category_id uuid REFERENCES public.coa_categories(id),
  transfer_account_id uuid REFERENCES public.ledger_accounts(id),
  payment_id uuid REFERENCES public.payments(id) ON DELETE SET NULL,
  memo text,
  status text NOT NULL DEFAULT 'uncategorized' CHECK (status IN ('uncategorized','categorized','reconciled','excluded')),
  is_split boolean NOT NULL DEFAULT false,
  import_batch_id uuid REFERENCES public.ledger_import_batches(id) ON DELETE SET NULL,
  fingerprint text NOT NULL,
  source text NOT NULL DEFAULT 'import' CHECK (source IN ('import','manual','auto')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, fingerprint)
);
CREATE INDEX idx_ledger_txn_account_date ON public.ledger_transactions(account_id, txn_date);

CREATE TABLE public.ledger_splits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  transaction_id uuid NOT NULL REFERENCES public.ledger_transactions(id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES public.coa_categories(id),
  amount numeric NOT NULL,
  memo text
);

-- ---------------------------------------------------------------------
-- INTEGRATION CONNECTIONS (phase 2 — one row per organization)
-- ---------------------------------------------------------------------
CREATE TABLE public.google_calendar_connection (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL UNIQUE REFERENCES public.organizations(id) ON DELETE CASCADE,
  calendar_id text,
  access_token text NOT NULL,
  refresh_token text NOT NULL,
  token_expires_at timestamptz NOT NULL,
  connected_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.quickbooks_connection (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL UNIQUE REFERENCES public.organizations(id) ON DELETE CASCADE,
  realm_id varchar(50) NOT NULL,
  access_token text NOT NULL,
  refresh_token text NOT NULL,
  token_expires_at timestamptz NOT NULL,
  connected_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
