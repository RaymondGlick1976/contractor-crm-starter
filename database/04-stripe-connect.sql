-- =====================================================================
-- YOURCRM — part 4: Stripe Connect (each business = connected account)
-- =====================================================================
SET search_path = public, extensions;

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS stripe_account_id text UNIQUE,
  ADD COLUMN IF NOT EXISTS stripe_charges_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stripe_details_submitted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stripe_connected_at timestamptz;

-- Browsers may rename their business / change timezone, but the Stripe link
-- is only ever written by server functions (service role).
REVOKE UPDATE ON public.organizations FROM authenticated, anon;
GRANT UPDATE (name, timezone) ON public.organizations TO authenticated;

-- Surface payment readiness to the app
CREATE OR REPLACE FUNCTION public.get_my_context()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org uuid := current_org_id(); r jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT jsonb_build_object(
    'user_id', auth.uid(),
    'email', auth.jwt() ->> 'email',
    'org', (SELECT jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug, 'timezone', o.timezone, 'plan', o.plan,
                   'payments_enabled', (o.stripe_account_id IS NOT NULL AND o.stripe_charges_enabled))
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
