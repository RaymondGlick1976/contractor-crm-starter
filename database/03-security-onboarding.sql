-- =====================================================================
-- YOURCRM — part 3: row-level security, onboarding, seed data
-- =====================================================================
SET search_path = public, extensions;

-- ---------------------------------------------------------------------
-- RLS: every tenant table is visible only inside the user's active org.
-- anon gets nothing; public pages go through Netlify functions.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'org_id'
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND c.relname NOT IN ('app_users','app_roles','invitations','google_calendar_connection','quickbooks_connection')
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON public.%I FOR ALL TO authenticated
                      USING (org_id = (SELECT current_org_id()))
                      WITH CHECK (org_id = (SELECT current_org_id()))', t);
  END LOOP;
END $$;

-- Staff directory & roles: everyone in the org can read; only user-managers can change.
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_users_read ON public.app_users FOR SELECT TO authenticated
  USING (org_id = (SELECT current_org_id()) OR user_id = auth.uid());
CREATE POLICY app_users_write ON public.app_users FOR ALL TO authenticated
  USING (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'))
  WITH CHECK (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'));
CREATE POLICY app_users_self_touch ON public.app_users FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

ALTER TABLE public.app_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY app_roles_read ON public.app_roles FOR SELECT TO authenticated
  USING (org_id = (SELECT current_org_id())
         OR id IN (SELECT role_id FROM app_users WHERE user_id = auth.uid()));
CREATE POLICY app_roles_write ON public.app_roles FOR ALL TO authenticated
  USING (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'))
  WITH CHECK (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'));

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
CREATE POLICY invitations_manage ON public.invitations FOR ALL TO authenticated
  USING (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'))
  WITH CHECK (org_id = (SELECT current_org_id()) AND has_org_permission('can_manage_users'));

-- Integration tokens: never readable from the browser (server functions only)
ALTER TABLE public.google_calendar_connection ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quickbooks_connection ENABLE ROW LEVEL SECURITY;

-- Organizations: members read; settings-admins rename
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
CREATE POLICY org_member_read ON public.organizations FOR SELECT TO authenticated
  USING (id IN (SELECT org_id FROM app_users WHERE user_id = auth.uid() AND is_active));
CREATE POLICY org_admin_update ON public.organizations FOR UPDATE TO authenticated
  USING (id = (SELECT current_org_id()) AND has_org_permission('can_access_settings'))
  WITH CHECK (id = (SELECT current_org_id()));

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY profiles_self_read ON public.profiles FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY profiles_self_update ON public.profiles FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid() AND (active_org_id IS NULL OR active_org_id IN
              (SELECT org_id FROM app_users WHERE user_id = auth.uid() AND is_active)));

-- Number generators & RPCs available to signed-in staff only
REVOKE EXECUTE ON FUNCTION public.generate_quote_number(uuid), public.generate_invoice_number(uuid),
  public.generate_job_number(uuid), public.generate_change_order_number(uuid),
  public.enroll_deal_in_sequence(uuid), public.increment_quote_views(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_quote_number(uuid), public.generate_invoice_number(uuid),
  public.generate_job_number(uuid), public.generate_change_order_number(uuid),
  public.enroll_deal_in_sequence(uuid), public.increment_quote_views(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- SEED DEFAULTS FOR A NEW ORGANIZATION
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_org_defaults(p_org uuid, p_name text, p_email text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lib uuid;
BEGIN
  INSERT INTO app_roles (org_id, name, description, can_access_settings, can_view_financials, can_delete,
    can_manage_users, can_send_invoices, can_edit_quotes, can_edit_customers, can_edit_pipeline, is_system,
    sort_order, can_view_quotes, can_view_invoices, can_view_customers, can_view_pipeline,
    can_accept_quotes, can_convert_quotes) VALUES
   (p_org,'Admin','Full access to everything',true,true,true,true,true,true,true,true,true,0,true,true,true,true,true,true),
   (p_org,'Office Manager','Quotes, invoices, customers. No settings access.',false,true,false,false,true,true,true,true,false,1,true,true,true,true,true,true),
   (p_org,'Sales','Customers, quotes and pipeline. No invoices or financials.',false,false,false,false,false,true,true,true,false,2,true,false,true,true,true,false),
   (p_org,'Crew','Pipeline only — view jobs and update status.',false,false,false,false,false,false,false,true,false,3,false,false,false,true,false,false);

  INSERT INTO job_stages (org_id, stage_id, label, color, sort_order) VALUES
   (p_org,'new-lead','New Lead','#6366f1',0),
   (p_org,'quotes','Estimate Scheduled','#64748b',1),
   (p_org,'quote-sent','Quote Sent','#0ea5e9',2),
   (p_org,'job-sold','Quote Accepted','#10b981',3),
   (p_org,'building','In Progress','#3b82f6',4),
   (p_org,'completed','Completed','#047857',5),
   (p_org,'job-lost','Lost / On Hold','#6b7280',6);

  INSERT INTO pricing_types (org_id, code, name, label, is_builtin, sort_order) VALUES
   (p_org,'sqft','Square Feet','per Sq. Ft.',true,0),
   (p_org,'linft','Linear Feet','per Lin. Ft.',true,1),
   (p_org,'each','Each','Each',true,2),
   (p_org,'percentage','Percentage','%',true,3);

  INSERT INTO lead_sources (org_id, name, sort_order)
  SELECT p_org, n, o FROM unnest(ARRAY['Referral','Google','Facebook','Instagram','Repeat Customer',
    'Yard Sign','Home Show','Nextdoor','Angi','Thumbtack','Website','Other']) WITH ORDINALITY AS t(n, o);

  INSERT INTO appointment_types (org_id, name, color, icon, sort_order) VALUES
   (p_org,'On-Site Estimate','#8b5cf6','📏',0),
   (p_org,'Site Visit','#3b82f6','🏠',1),
   (p_org,'Phone Call','#10b981','📞',2),
   (p_org,'Project Start','#06b6d4','🔨',3),
   (p_org,'Other','#64748b','📅',4);

  INSERT INTO job_event_types (org_id, name, color, icon, sort_order) VALUES
   (p_org,'Order Materials','#3b82f6','🚚',0),
   (p_org,'Measurements','#8b5cf6','📏',1),
   (p_org,'Installation','#ef4444','🏠',2),
   (p_org,'Punch List','#64748b','✅',3);

  INSERT INTO libraries (org_id, name, is_default, sort_order) VALUES (p_org, 'My Catalog', true, 0)
  RETURNING id INTO v_lib;

  INSERT INTO payment_schedule_templates (org_id, name, description, is_default) VALUES
   (p_org, '50 / 50', '50% deposit, 50% on completion', true);
  INSERT INTO payment_schedule_template_items (org_id, template_id, name, due_description, amount_type, amount_value, sort_order)
  SELECT p_org, id, 'Deposit', 'Due at signing', 'percentage', 50, 0 FROM payment_schedule_templates WHERE org_id = p_org
  UNION ALL
  SELECT p_org, id, 'Final Payment', 'Due on completion', 'percentage', 50, 1 FROM payment_schedule_templates WHERE org_id = p_org;

  INSERT INTO coa_categories (org_id, name, cat_type, schedule_c_line, system_key, sort_order)
  SELECT p_org, n, t, s, k, row_number() OVER () FROM (VALUES
   ('Sales Income','income','Line 1 — Gross receipts','sales_income'),
   ('Customer Refunds (Returns)','income','Line 2 — Returns and allowances',NULL),
   ('Other Income','income','Line 6 — Other income',NULL),
   ('Materials & Supplies (COGS)','cogs','Part III, Line 38 — Materials and supplies',NULL),
   ('Subcontractors (COGS)','cogs','Part III, Line 37 — Cost of labor',NULL),
   ('Advertising & Marketing','expense','Line 8 — Advertising',NULL),
   ('Vehicle & Truck Expenses','expense','Line 9 — Car and truck expenses',NULL),
   ('Fuel','expense','Line 9 — Car and truck expenses',NULL),
   ('Commissions & Fees','expense','Line 10 — Commissions and fees',NULL),
   ('Contract Labor','expense','Line 11 — Contract labor',NULL),
   ('Insurance','expense','Line 15 — Insurance',NULL),
   ('Legal & Professional Services','expense','Line 17 — Legal and professional services',NULL),
   ('Office Expense','expense','Line 18 — Office expense',NULL),
   ('Equipment Rental','expense','Line 20a — Rent (machinery/equipment)',NULL),
   ('Rent — Shop / Business Property','expense','Line 20b — Rent (other business property)',NULL),
   ('Repairs & Maintenance','expense','Line 21 — Repairs and maintenance',NULL),
   ('Supplies','expense','Line 22 — Supplies',NULL),
   ('Small Tools & Equipment','expense','Line 22 — Supplies',NULL),
   ('Taxes & Licenses','expense','Line 23 — Taxes and licenses',NULL),
   ('Travel','expense','Line 24a — Travel',NULL),
   ('Meals (50% deductible)','expense','Line 24b — Deductible meals',NULL),
   ('Utilities','expense','Line 25 — Utilities',NULL),
   ('Wages','expense','Line 26 — Wages',NULL),
   ('Phone & Internet','expense','Line 27a — Other expenses',NULL),
   ('Software & Subscriptions','expense','Line 27a — Other expenses',NULL),
   ('Bank & Merchant Fees','expense','Line 27a — Other expenses',NULL),
   ('Other Business Expenses','expense','Line 27a — Other expenses',NULL),
   ('Transfer Between Accounts','transfer',NULL,'transfer'),
   ('Credit Card Payment','transfer',NULL,'cc_payment'),
   ('Owner''s Draw (Personal)','equity',NULL,'owner_draw'),
   ('Owner Investment','equity',NULL,'owner_investment'),
   ('Sales Tax Remitted','liability',NULL,'sales_tax'),
   ('Loan Principal Payment','liability',NULL,NULL),
   ('Uncategorized','uncategorized',NULL,'uncategorized')
  ) AS v(n, t, s, k);

  INSERT INTO settings (org_id, key, value) VALUES
   (p_org,'company', jsonb_build_object('name', p_name, 'email', p_email, 'from_email', p_email,
      'notification_email', p_email, 'phone', '', 'address', '', 'city', '', 'state', '', 'zip', '', 'website', '')),
   (p_org,'branding', '{"color": "#3e855f", "tagline": "", "logo_url": null}'),
   (p_org,'next_quote_number', '{"value": 1001}'),
   (p_org,'next_invoice_number', '{"value": 1001}'),
   (p_org,'next_job_number', '{"value": 1001}'),
   (p_org,'next_change_order_number', '{"value": 1001}'),
   (p_org,'quote_defaults', '{"tax_rate": 0, "valid_days": 30, "deposit_type": "percentage", "deposit_value": 50}'),
   (p_org,'invoice_defaults', '{"due_days": 30, "tax_rate": 0}'),
   (p_org,'invoices', '{"late_fee_percent": 0, "default_payment_terms": 30}'),
   (p_org,'quotes', '{"default_deposit": 50, "default_tax_rate": 0, "default_valid_days": 30}'),
   (p_org,'dashboard', '{"pipeline_stages": ["new-lead", "quotes"]}'),
   (p_org,'deal_item_types', '[]'),
   (p_org,'finish_types', '[]'),
   (p_org,'notifications', '{"new_booking": true, "quote_viewed": true, "invoice_viewed": true, "quote_accepted": true, "quote_declined": true, "reminder_hours": 4, "customer_upload": true, "new_appointment": true, "payment_received": true, "job_stage_changed": false}'),
   (p_org,'quote_footer', '{"title": "", "buttons": []}'),
   (p_org,'terms_and_conditions', jsonb_build_object('quote',
      'All work will be completed in a professional, workmanlike manner. Changes to the approved scope that affect cost require written approval and are billed in addition to this estimate.'));
END $$;
REVOKE EXECUTE ON FUNCTION public.seed_org_defaults(uuid, text, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- ONBOARDING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.slugify(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(both '-' from regexp_replace(lower(coalesce(p,'')), '[^a-z0-9]+', '-', 'g'));
$$;

-- Creates a business, seeds it, makes p_user its Admin and switches them into it.
CREATE OR REPLACE FUNCTION public.create_organization_for(p_user uuid, p_email text, p_business text, p_full_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid; v_slug text; v_role uuid; n int := 0;
BEGIN
  IF p_user IS NULL OR coalesce(trim(p_business),'') = '' THEN RAISE EXCEPTION 'Business name required'; END IF;
  v_slug := nullif(slugify(p_business), '');
  v_slug := coalesce(v_slug, 'business');
  WHILE EXISTS (SELECT 1 FROM organizations WHERE slug = v_slug || CASE WHEN n = 0 THEN '' ELSE '-' || n END) LOOP
    n := n + 1;
  END LOOP;
  IF n > 0 THEN v_slug := v_slug || '-' || n; END IF;

  INSERT INTO organizations (name, slug, created_by) VALUES (trim(p_business), v_slug, p_user) RETURNING id INTO v_org;
  PERFORM seed_org_defaults(v_org, trim(p_business), p_email);
  SELECT id INTO v_role FROM app_roles WHERE org_id = v_org AND name = 'Admin';
  INSERT INTO app_users (org_id, user_id, email, name, role_id)
  VALUES (v_org, p_user, lower(p_email), coalesce(nullif(trim(p_full_name),''), split_part(p_email,'@',1)), v_role);
  INSERT INTO profiles (user_id, full_name, active_org_id) VALUES (p_user, p_full_name, v_org)
  ON CONFLICT (user_id) DO UPDATE SET active_org_id = EXCLUDED.active_org_id,
        full_name = COALESCE(profiles.full_name, EXCLUDED.full_name);
  RETURN v_org;
END $$;
REVOKE EXECUTE ON FUNCTION public.create_organization_for(uuid, text, text, text) FROM PUBLIC, anon, authenticated;

-- A signed-in user adds another business they own
CREATE OR REPLACE FUNCTION public.create_organization(p_business text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email text := auth.jwt() ->> 'email'; v_name text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  SELECT full_name INTO v_name FROM profiles WHERE user_id = auth.uid();
  RETURN create_organization_for(auth.uid(), v_email, p_business, v_name);
END $$;
REVOKE EXECUTE ON FUNCTION public.create_organization(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_organization(text) TO authenticated;

-- Accept an emailed invitation (email on the invite must match the signed-in user)
CREATE OR REPLACE FUNCTION public.accept_invitation(p_token uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE inv RECORD; v_email text := lower(auth.jwt() ->> 'email');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not signed in'; END IF;
  SELECT * INTO inv FROM invitations WHERE token = p_token;
  IF NOT FOUND OR inv.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'Invitation not found'; END IF;
  IF inv.accepted_at IS NOT NULL THEN RAISE EXCEPTION 'Invitation already used'; END IF;
  IF inv.expires_at < now() THEN RAISE EXCEPTION 'Invitation expired'; END IF;
  IF lower(inv.email) <> v_email THEN RAISE EXCEPTION 'This invitation was sent to a different email address'; END IF;

  INSERT INTO app_users (org_id, user_id, email, name, role_id)
  VALUES (inv.org_id, auth.uid(), v_email, coalesce(nullif(inv.name,''), split_part(v_email,'@',1)), inv.role_id)
  ON CONFLICT (org_id, user_id) DO UPDATE SET is_active = true, role_id = EXCLUDED.role_id;
  UPDATE invitations SET accepted_at = now() WHERE id = inv.id;
  INSERT INTO profiles (user_id, full_name, active_org_id) VALUES (auth.uid(), inv.name, inv.org_id)
  ON CONFLICT (user_id) DO UPDATE SET active_org_id = inv.org_id;
  RETURN inv.org_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.accept_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_invitation(uuid) TO authenticated;

-- Invite details for the accept page (works before sign-in, reveals only what's needed)
CREATE OR REPLACE FUNCTION public.get_invitation(p_token uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('email', i.email, 'name', i.name, 'business', o.name,
         'valid', i.accepted_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > now(),
         'has_account', EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = lower(i.email)))
    FROM invitations i JOIN organizations o ON o.id = i.org_id WHERE i.token = p_token;
$$;
GRANT EXECUTE ON FUNCTION public.get_invitation(uuid) TO anon, authenticated;

-- Everything the app needs after sign-in: who am I, which business, my permissions, my other businesses
CREATE OR REPLACE FUNCTION public.get_my_context()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid := current_org_id(); r jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'user_id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'org', (SELECT jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug, 'timezone', o.timezone, 'plan', o.plan)
              FROM organizations o WHERE o.id = v_org),
    'member', (SELECT jsonb_build_object('id', u.id, 'name', u.name, 'role_id', u.role_id, 'role', to_jsonb(rl))
                 FROM app_users u LEFT JOIN app_roles rl ON rl.id = u.role_id
                WHERE u.org_id = v_org AND u.user_id = auth.uid()),
    'orgs', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name) ORDER BY o.name)
                        FROM app_users u JOIN organizations o ON o.id = u.org_id
                       WHERE u.user_id = auth.uid() AND u.is_active), '[]'::jsonb)
  ) INTO r;
  UPDATE app_users SET last_login = now() WHERE org_id = v_org AND user_id = auth.uid();
  RETURN r;
END $$;
REVOKE EXECUTE ON FUNCTION public.get_my_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_context() TO authenticated;

CREATE OR REPLACE FUNCTION public.switch_organization(p_org uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app_users WHERE user_id = auth.uid() AND org_id = p_org AND is_active) THEN
    RAISE EXCEPTION 'Not a member of that business';
  END IF;
  INSERT INTO profiles (user_id, active_org_id) VALUES (auth.uid(), p_org)
  ON CONFLICT (user_id) DO UPDATE SET active_org_id = p_org;
END $$;
REVOKE EXECUTE ON FUNCTION public.switch_organization(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.switch_organization(uuid) TO authenticated;

-- Helper functions are internal
REVOKE EXECUTE ON FUNCTION public.fill_org_id() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- STORAGE: one public bucket; writes only inside your org's folder
-- ---------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public) VALUES ('Uploads', 'Uploads', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "org folder insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'Uploads' AND (storage.foldername(name))[1] = (SELECT current_org_id())::text);
CREATE POLICY "org folder update" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'Uploads' AND (storage.foldername(name))[1] = (SELECT current_org_id())::text);
CREATE POLICY "org folder delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'Uploads' AND (storage.foldername(name))[1] = (SELECT current_org_id())::text);
CREATE POLICY "org folder read" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'Uploads' AND (storage.foldername(name))[1] = (SELECT current_org_id())::text);
