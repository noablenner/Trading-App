// ============================================================================
// Edge Function : stripe-webhook  ——  SOURCE DE VÉRITÉ de l'abonnement
// ----------------------------------------------------------------------------
// Appelée par Stripe (pas par le front). C'est le SEUL endroit qui fait passer
// un compte en `active`. Le front n'est jamais cru sur parole.
//
//   1. Vérifie la SIGNATURE de l'événement (STRIPE_WEBHOOK_SECRET). Rejette sinon.
//   2. Traite : checkout.session.completed, customer.subscription.updated,
//      customer.subscription.deleted, invoice.payment_failed.
//   3. Retrouve le profil (via metadata.user_id / client_reference_id ou
//      stripe_customer_id) et met à jour profiles.subscription_status.
//
// ⚠️ Cette fonction doit être déployée SANS vérification de JWT
//    (config.toml : [functions.stripe-webhook] verify_jwt = false),
//    car Stripe l'appelle sans JWT Supabase — la sécurité vient de la signature.
//
// Secrets : STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY sont injectés par Supabase.
// ============================================================================

import Stripe from "https://esm.sh/stripe@17.7.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

const stripe = new Stripe(STRIPE_SECRET_KEY, {
  httpClient: Stripe.createFetchHttpClient(),
});
// Nécessaire en Deno : vérification de signature asynchrone (Web Crypto).
const cryptoProvider = Stripe.createSubtleCryptoProvider();

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// Traduit un statut d'abonnement Stripe vers nos 4 valeurs.
function mapStatus(stripeStatus: string): string {
  switch (stripeStatus) {
    case "active":
    case "trialing":
      return "active"; // accès complet accordé par abonnement
    case "past_due":
    case "unpaid":
      return "past_due";
    case "canceled":
    case "incomplete_expired":
      return "canceled";
    default:
      return "past_due";
  }
}

// Met à jour un profil identifié par user_id (prioritaire) ou stripe_customer_id.
async function updateProfile(
  match: { userId?: string | null; customerId?: string | null },
  patch: Record<string, unknown>,
) {
  let q = supabaseAdmin.from("profiles").update(patch);
  if (match.userId) {
    q = q.eq("id", match.userId);
  } else if (match.customerId) {
    q = q.eq("stripe_customer_id", match.customerId);
  } else {
    console.warn("updateProfile: aucun identifiant pour retrouver le profil");
    return;
  }
  const { error } = await q;
  if (error) console.error("updateProfile error:", error);
}

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  if (!signature) {
    return new Response("Signature manquante", { status: 400 });
  }

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      WEBHOOK_SECRET,
      undefined,
      cryptoProvider,
    );
  } catch (err) {
    console.error("Signature invalide:", err);
    return new Response("Signature invalide", { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId =
          (session.metadata?.user_id as string | undefined) ??
          session.client_reference_id ??
          null;
        const customerId = (session.customer as string | null) ?? null;
        const subscriptionId = (session.subscription as string | null) ?? null;
        await updateProfile(
          { userId, customerId },
          {
            subscription_status: "active",
            stripe_customer_id: customerId ?? undefined,
            stripe_subscription_id: subscriptionId ?? undefined,
          },
        );
        break;
      }

      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        await updateProfile(
          {
            userId: (sub.metadata?.user_id as string | undefined) ?? null,
            customerId: sub.customer as string,
          },
          {
            subscription_status: mapStatus(sub.status),
            stripe_subscription_id: sub.id,
          },
        );
        break;
      }

      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        await updateProfile(
          {
            userId: (sub.metadata?.user_id as string | undefined) ?? null,
            customerId: sub.customer as string,
          },
          { subscription_status: "canceled" },
        );
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        await updateProfile(
          { customerId: (invoice.customer as string | null) ?? null },
          { subscription_status: "past_due" },
        );
        break;
      }

      default:
        // Événements non gérés : on répond 200 pour que Stripe ne réessaie pas.
        break;
    }

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("Erreur de traitement du webhook:", err);
    return new Response("Erreur de traitement", { status: 500 });
  }
});
