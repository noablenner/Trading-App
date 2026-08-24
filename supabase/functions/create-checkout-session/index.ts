// ============================================================================
// Edge Function : create-checkout-session
// ----------------------------------------------------------------------------
// Appelée par l'app (utilisateur connecté) quand il clique « S'abonner ».
//   1. Identifie l'utilisateur via son JWT Supabase.
//   2. Crée (ou réutilise) un Customer Stripe, stocké dans profiles.stripe_customer_id.
//   3. Crée une Checkout Session Stripe en mode `subscription` avec le prix Premium.
//   4. Renvoie l'URL de paiement ; le front redirige dessus.
//
// La clé secrète Stripe n'est JAMAIS exposée au front : tout se passe ici.
// Secrets lus depuis l'environnement : STRIPE_SECRET_KEY, (STRIPE_PRICE_ID),
// (APP_URL). SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont injectés par Supabase.
// ============================================================================

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
// Prix Premium (mode test) — surchargeable par variable d'env si besoin.
const PRICE_ID = Deno.env.get("STRIPE_PRICE_ID") ?? "price_1U82IDAtMxpgZksHeXLC84Rq";
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
    // ---- 1. Identifier l'utilisateur à partir de son JWT ----
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(jwt);
    if (userErr || !userData?.user) {
      return json({ error: "Non authentifié." }, 401);
    }
    const user = userData.user;

    // ---- 2. Récupérer le profil (customer Stripe, prénom/nom) ----
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("stripe_customer_id, first_name, last_name")
      .eq("id", user.id)
      .maybeSingle();

    let customerId = profile?.stripe_customer_id ?? null;

    // ---- 3. Créer le Customer Stripe si nécessaire ----
    if (!customerId) {
      const fullName = [profile?.first_name, profile?.last_name]
        .filter(Boolean)
        .join(" ")
        .trim();
      const customer = await stripe.customers.create({
        email: user.email ?? undefined,
        name: fullName || undefined,
        metadata: { user_id: user.id },
      });
      customerId = customer.id;
      await supabaseAdmin
        .from("profiles")
        .update({ stripe_customer_id: customerId })
        .eq("id", user.id);
    }

    // ---- 4. Créer la Checkout Session ----
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      line_items: [{ price: PRICE_ID, quantity: 1 }],
      client_reference_id: user.id,
      subscription_data: { metadata: { user_id: user.id } },
      metadata: { user_id: user.id },
      allow_promotion_codes: true,
      locale: "fr",
      success_url: `${APP_URL}/?checkout=success`,
      cancel_url: `${APP_URL}/?checkout=cancel`,
    });

    return json({ url: session.url }, 200);
  } catch (err) {
    console.error("create-checkout-session error:", err);
    return json({ error: "Impossible de créer la session de paiement." }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
