// ============================================================================
// Edge Function : create-portal-session (optionnelle mais bienvenue)
// ----------------------------------------------------------------------------
// Ouvre le Billing Portal Stripe pour que l'utilisateur gère / annule son
// abonnement, met à jour sa carte, télécharge ses factures — sans qu'on code
// ces écrans.
//
// Secrets : STRIPE_SECRET_KEY, (APP_URL).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injectés par Supabase.
// ============================================================================

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const APP_URL = (Deno.env.get("APP_URL") ?? "https://app.edgio.fr").replace(/\/+$/, "");

const stripe = new Stripe(STRIPE_SECRET_KEY, {
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return json({ error: "Non authentifié." }, 401);
    }

    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("stripe_customer_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (!profile?.stripe_customer_id) {
      return json({ error: "Aucun abonnement à gérer pour le moment." }, 400);
    }

    const portal = await stripe.billingPortal.sessions.create({
      customer: profile.stripe_customer_id,
      return_url: `${APP_URL}/`,
    });

    return json({ url: portal.url }, 200);
  } catch (err) {
    console.error("create-portal-session error:", err);
    return json({ error: "Impossible d'ouvrir l'espace d'abonnement." }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
