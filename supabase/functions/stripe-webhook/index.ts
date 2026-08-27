// Edge Function: stripe-webhook
// Source de vérité du statut d'abonnement. Vérifie la signature Stripe puis
// met à jour public.profiles avec la clé service_role (bypass RLS).
// Déployée avec verify_jwt=false (voir supabase/config.toml) : Stripe n'envoie
// pas de JWT Supabase, la sécurité vient de la vérification de signature ci-dessous.
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17.0.0";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-06-20" });
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

async function resolveUserId(customerId: string | null, fromMetadata?: string | null): Promise<string | null> {
  if (fromMetadata) return fromMetadata;
  if (!customerId) return null;
  const { data } = await admin
    .from("profiles")
    .select("id")
    .eq("stripe_customer_id", customerId)
    .maybeSingle();
  return data?.id ?? null;
}

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  let event: Stripe.Event;
  try {
    if (!signature) throw new Error("Signature Stripe manquante.");
    event = await stripe.webhooks.constructEventAsync(body, signature, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error("Signature webhook invalide", err);
    return new Response(`Webhook signature verification failed: ${err}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const userId = await resolveUserId(
          (session.customer as string) ?? null,
          session.client_reference_id ?? (session.metadata?.user_id as string | undefined) ?? null
        );
        if (userId) {
          await admin
            .from("profiles")
            .update({
              subscription_status: "active",
              stripe_customer_id: (session.customer as string) ?? undefined,
              stripe_subscription_id: (session.subscription as string) ?? undefined,
            })
            .eq("id", userId);
        }
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.created": {
        const sub = event.data.object as Stripe.Subscription;
        const userId = await resolveUserId(
          (sub.customer as string) ?? null,
          (sub.metadata?.user_id as string | undefined) ?? null
        );
        if (userId) {
          const status =
            sub.status === "active" || sub.status === "trialing"
              ? "active"
              : sub.status === "past_due" || sub.status === "unpaid" || sub.status === "incomplete"
              ? "past_due"
              : "canceled";
          await admin
            .from("profiles")
            .update({ subscription_status: status, stripe_subscription_id: sub.id })
            .eq("id", userId);
        }
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const userId = await resolveUserId(
          (sub.customer as string) ?? null,
          (sub.metadata?.user_id as string | undefined) ?? null
        );
        if (userId) {
          await admin.from("profiles").update({ subscription_status: "canceled" }).eq("id", userId);
        }
        break;
      }
      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        const userId = await resolveUserId((invoice.customer as string) ?? null, null);
        if (userId) {
          await admin.from("profiles").update({ subscription_status: "past_due" }).eq("id", userId);
        }
        break;
      }
      default:
        break;
    }
  } catch (e) {
    console.error("stripe-webhook processing error", e);
    return new Response("Webhook handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
