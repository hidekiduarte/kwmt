/* KWMT — proteção de acesso ao painel.
 * Somente usuários autenticados como proprietários ativos podem abrir o painel.
 */
(() => {
  "use strict";
  const app = document.querySelector(".app");
  if (app) app.style.visibility = "hidden";

  const cfg = window.KWMT_SUPABASE_CONFIG || {};
  const goToLogin = () => { window.location.replace("./login.html"); };

  if (!cfg.url || !cfg.publishableKey || !window.supabase?.createClient) {
    console.error("[KWMT] Configuração de autenticação indisponível.");
    goToLogin();
    return;
  }

  const client = window.supabase.createClient(cfg.url, cfg.publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  (async () => {
    try {
      const { data, error } = await client.auth.getSession();
      if (error || !data.session?.user) return goToLogin();

      const { data: memberships, error: membershipError } = await client
        .from("school_members")
        .select("school_id")
        .eq("user_id", data.session.user.id)
        .eq("role", "owner")
        .eq("active", true)
        .limit(1);

      if (membershipError || !memberships?.length) return goToLogin();
      if (app) app.style.visibility = "visible";
    } catch (error) {
      console.error("[KWMT] Não foi possível validar o acesso:", error);
      goToLogin();
    }
  })();
})();
