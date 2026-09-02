// Edge Function: symbol-search
// Relaie une recherche de symbole vers l'API publique de TradingView.
// Le navigateur ne peut pas appeler symbol-search.tradingview.com directement
// (CORS refusé côté TradingView) : cette fonction fait l'appel côté serveur
// (aucune restriction CORS entre deux serveurs) et renvoie un JSON simplifié,
// avec nos propres en-têtes CORS pour que l'app puisse la lire.
import { corsHeaders } from "../_shared/cors.ts";

interface TvRawSymbol {
  symbol?: string;
  description?: string;
  type?: string;
  exchange?: string;
  source_id?: string;
  prefix?: string;
}

function stripTags(s: string | undefined): string {
  return String(s ?? "").replace(/<[^>]*>/g, "");
}

async function fetchTv(url: string): Promise<TvRawSymbol[]> {
  const r = await fetch(url, {
    headers: {
      // Certains points TradingView refusent les requêtes sans User-Agent / Origin plausibles.
      "User-Agent": "Mozilla/5.0 (compatible; EdgioSymbolSearch/1.0)",
      "Origin": "https://www.tradingview.com",
      "Referer": "https://www.tradingview.com/",
    },
  });
  if (!r.ok) throw new Error("tv http " + r.status);
  const data = await r.json();
  if (Array.isArray(data)) return data as TvRawSymbol[];
  if (Array.isArray((data as any)?.symbols)) return (data as any).symbols as TvRawSymbol[];
  return [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const url = new URL(req.url);
    let q = url.searchParams.get("q") || url.searchParams.get("text") || "";
    if (req.method === "POST") {
      try {
        const body = await req.json();
        q = body?.q || body?.text || q;
      } catch (_e) { /* pas de corps JSON, on garde le paramètre d'URL */ }
    }
    q = String(q || "").trim();
    if (!q) {
      return new Response(JSON.stringify({ results: [] }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const enc = encodeURIComponent(q);
    const urls = [
      `https://symbol-search.tradingview.com/symbol_search/v3/?text=${enc}&hl=1&lang=fr&domain=production&sort_by_country=US`,
      `https://symbol-search.tradingview.com/symbol_search/?text=${enc}&type=`,
    ];

    let raw: TvRawSymbol[] = [];
    let lastErr: unknown = null;
    for (const u of urls) {
      try {
        raw = await fetchTv(u);
        if (raw.length) break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (!raw.length && lastErr) throw lastErr;

    const results = raw
      .map((it) => {
        const symbol = stripTags(it.symbol);
        const exch = it.exchange || it.source_id || it.prefix || "";
        return {
          symbol,
          full: exch ? `${exch}:${symbol}` : symbol,
          description: stripTags(it.description),
          type: it.type || "",
        };
      })
      .filter((x) => x.symbol);

    return new Response(JSON.stringify({ results }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("symbol-search error", e);
    return new Response(JSON.stringify({ results: [], error: "Erreur serveur." }), {
      status: 200, // on renvoie 200 + liste vide : l'app retombe alors sur sa liste locale sans erreur bruyante
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
