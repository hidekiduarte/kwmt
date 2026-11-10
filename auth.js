(() => {
  const $ = (id) => document.getElementById(id);
  const cfg = window.KWMT_SUPABASE_CONFIG || {};
  const validConfig = cfg.url && cfg.publishableKey &&
    cfg.url.startsWith("https://") &&
    !cfg.url.includes("COLE_AQUI") &&
    !cfg.publishableKey.includes("COLE_AQUI");
  const status = (message, error = false) => {
    const el = $("authStatus");
    el.textContent = message;
    el.classList.toggle("error", error);
    el.hidden = false;
  };
  let mode = "owner";
  let supabaseClient = null;

  function setMode(next) {
    mode = next;
    document.querySelectorAll("[data-role]").forEach((el) => {
      const selected = el.dataset.role === mode;
      el.classList.toggle("selected", selected);
      el.setAttribute("aria-pressed", String(selected));
    });
    $("ownerFields").hidden = mode !== "owner";
    $("authTitle").textContent = mode === "owner" ? "Acesse sua escola." : "Acesse sua agenda.";
    $("authDescription").textContent = mode === "owner"
      ? "Entre ou crie a conta responsável pela gestão da escola."
      : "Entre com o e-mail e a senha vinculados ao convite da sua escola.";
    $("authSubmit").textContent = mode === "owner" ? "Entrar / criar conta" : "Entrar como professor";
  }

  document.querySelectorAll("[data-role]").forEach((el) =>
    el.addEventListener("click", () => setMode(el.dataset.role))
  );

  if (!validConfig) {
    status("Falta configurar a Project URL e a Publishable key do Supabase. O acesso ficará desativado até isso ser feito.");
  } else if (!window.supabase?.createClient) {
    status("Não foi possível carregar a biblioteca de conexão. Verifique sua internet e recarregue a página.", true);
  } else {
    supabaseClient = window.supabase.createClient(cfg.url, cfg.publishableKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    supabaseClient.auth.getSession().then(({ data, error }) => {
      if (error) status("Não consegui verificar sua sessão: " + error.message, true);
      else if (data.session) status("Você já está autenticado. A próxima etapa é conectar seus dados ao painel.");
    });
  }

  $("authForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!supabaseClient) {
      status("A conexão ainda não foi configurada. Precisamos inserir a Project URL e a Publishable key.", true);
      return;
    }
    const email = $("email").value.trim();
    const password = $("password").value;
    const button = $("authSubmit");
    button.disabled = true;
    button.textContent = "Conectando…";
    try {
      let result;
      if (mode === "owner" && $("ownerName").value.trim() && $("schoolName").value.trim()) {
        const fullName = $("ownerName").value.trim();
        const schoolName = $("schoolName").value.trim();
        result = await supabaseClient.auth.signUp({
          email,
          password,
          options: {
            data: { full_name: fullName },
            // Retorna para a própria tela de acesso do KWMT após confirmar o e-mail.
            emailRedirectTo: window.location.href.split("#")[0]
          }
        });
        if (result.error) throw result.error;
        if (result.data.session) {
          const created = await supabaseClient.rpc("create_school", {
            school_name: schoolName,
            operation_kind: "surf_school"
          });
          if (created.error) throw created.error;
          status("Conta criada e escola registrada no banco. A próxima etapa é carregar os dados reais no painel.");
        } else {
          localStorage.setItem("kwmt_pending_school", JSON.stringify({
            name: schoolName, operation: "surf_school"
          }));
          status("Conta iniciada. Confirme seu e-mail e depois entre com sua senha para concluir o cadastro da escola.");
        }
      } else {
        result = await supabaseClient.auth.signInWithPassword({ email, password });
        if (result.error) throw result.error;
        if (mode === "owner") {
          const pending = localStorage.getItem("kwmt_pending_school");
          if (pending) {
            const school = JSON.parse(pending);
            const created = await supabaseClient.rpc("create_school", {
              school_name: school.name,
              operation_kind: school.operation || "surf_school"
            });
            if (created.error) throw created.error;
            localStorage.removeItem("kwmt_pending_school");
            status("Acesso confirmado e escola cadastrada. Próxima etapa: painel conectado.");
          } else {
            const membership = await supabaseClient.from("school_members")
              .select("role,school_id").eq("user_id", result.data.user.id)
              .eq("role", "owner").eq("active", true);
            if (membership.error) throw membership.error;
            if (!membership.data.length) throw new Error("Esta conta ainda não está vinculada como proprietária de uma escola.");
            status("Login confirmado. Sua conta de proprietário está vinculada à KWMT.");
          }
        } else {
          const membership = await supabaseClient.from("school_members")
            .select("role,school_id").eq("user_id", result.data.user.id)
            .eq("role", "teacher").eq("active", true);
          if (membership.error) throw membership.error;
          if (!membership.data.length) throw new Error("Esta conta ainda não recebeu um convite ativo de professor.");
          status("Login de professor confirmado. A próxima etapa é abrir a agenda vinculada à sua escola.");
        }
      }
    } catch (error) {
      status(error.message || "Não foi possível concluir o acesso.", true);
    } finally {
      button.disabled = false;
      button.textContent = mode === "owner" ? "Entrar / criar conta" : "Entrar como professor";
    }
  });

  $("signOut").addEventListener("click", async () => {
    if (!supabaseClient) return;
    const { error } = await supabaseClient.auth.signOut();
    if (error) status(error.message, true);
    else status("Você saiu da sua conta.");
  });

  setMode("owner");
})();
