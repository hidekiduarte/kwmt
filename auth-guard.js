(() => {
  const loginUrl = "./login.html";
  const showBlocked = (message) => {
    document.body.innerHTML = '<main style="min-height:100vh;display:grid;place-items:center;padding:24px;background:#07152f;color:white;font:16px system-ui;text-align:center"><section><h1>KWMT</h1><p id="guard-message"></p><a href="./login.html" style="color:#9ddcff">Ir para o login</a></section></main>';
    document.getElementById("guard-message").textContent = message;
    document.body.style.visibility = "visible";
  };
  const cfg = window.KWMT_SUPABASE_CONFIG || {};
  if (!cfg.url || !cfg.publishableKey || !window.supabase?.createClient) {
    showBlocked("Não foi possível iniciar a autenticação. Recarregue a página ou entre novamente.");
    return;
  }
  const client = window.supabase.createClient(cfg.url, cfg.publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
  client.auth.getSession().then(async ({ data, error }) => {
    if (error) throw error;
    if (!data.session?.user) {
      window.location.replace(loginUrl);
      return;
    }
    const { data: memberships, error: memberError } = await client
      .from("school_members")
      .select("school_id")
      .eq("user_id", data.session.user.id)
      .eq("role", "owner")
      .eq("active", true)
      .limit(1);
    if (memberError) throw memberError;
    if (!memberships?.length) {
      await client.auth.signOut();
      window.location.replace(loginUrl);
      return;
    }
    document.body.style.visibility = "visible";
  }).catch((error) => {
    console.error("KWMT auth guard:", error);
    showBlocked("Não foi possível validar seu acesso. Verifique sua conexão e entre novamente.");
  });
})();