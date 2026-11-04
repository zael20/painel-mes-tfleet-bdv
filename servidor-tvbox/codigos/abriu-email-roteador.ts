// Monitor Frota: rastreio de abertura do e-mail do resumo de roteador.
// Supabase > Edge Functions > Create a new function > nome: abriu-email-roteador > colar este codigo > Deploy.
// IMPORTANTE: desligar "Verify JWT" dessa funcao (a imagem do e-mail nao manda login).
// Quem carrega a imagem (?ids=1,2,3) grava email_aberto_em nos usos ainda sem registro de abertura.
// Responde sempre uma imagem 1x1 transparente, mesmo se algo falhar.
import { createClient } from "npm:@supabase/supabase-js@2";

const GIF = Uint8Array.from(
  atob("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"),
  (c) => c.charCodeAt(0),
);

Deno.serve(async (req) => {
  try {
    const ids = (new URL(req.url).searchParams.get("ids") || "")
      .split(",")
      .map(Number)
      .filter((n) => Number.isInteger(n) && n > 0)
      .slice(0, 200);
    if (ids.length) {
      const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      await sb
        .from("roteador_tratativas")
        .update({ email_aberto_em: new Date().toISOString() })
        .in("event_id", ids)
        .is("email_aberto_em", null);
    }
  } catch (_) {
    // segue: a imagem sai mesmo assim
  }
  return new Response(GIF, {
    headers: { "Content-Type": "image/gif", "Cache-Control": "no-store" },
  });
});
