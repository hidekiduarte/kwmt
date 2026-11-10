(() => {
  const $ = (id) => document.getElementById(id);
  const cfg = window.KWMT_SUPABASE_CONFIG || {};
  const validConfig = cfg.url && cfg.publishableKey && cfg.url.startsWith("https://");
  let client = null;
  let role = "owner";
  let flow = "signup";

  const status = (message, error = false) => {
    const el = $("authStatus");
    el.textContent = message;
    el.classList.toggle("error", error);
    el.hidden = false;
  };
  const friendlyError = (error) => {
    const msg = String(error?.message || "");
    if (/after \d+ seconds|rate limit|too many requests/i.test(msg)) {
      const seconds = msg.match(/(\d+) seconds/i)?.[1];
      return "O Supabase está limitando novas tentativas por segurança" +
        (seconds ? ". Aguarde " + seconds + " segundos" : "") +
        " e tente novamente uma única vez. Não precisa preencher tudo de novo.";
    }
    if (/already registered|user already exists/i.test(msg)) {
      return "Este e-mail já tem uma conta. Escolha “Já tenho conta” e entre com sua senha.";
    }
    if (/email not confirmed/i.test(msg)) {
      return "Seu e-mail ainda não foi confirmado. Abra a mensagem enviada pelo Supabase e confirme o cadastro antes de entrar.";
    }
    return msg || "Não foi possível concluir. Confira os dados e tente novamente.";
  };

  function render() {
    document.querySelectorAll("[data-role]").forEach((el) => {
      const selected = el.dataset.role === role;
      el.classList.toggle("selected", selected);
      el.setAttribute("aria-pressed", String(selected));
    });
    document.querySelectorAll("[data-flow]").forEach((el) => {
      const selected = el.dataset.flow === flow;
      el.classList.toggle("selected", selected);
      el.setAttribute("aria-pressed", String(selected));
    });
    $("ownerFields").hidden = role !== "owner" || flow !== "signup";
    $("authTitle").textContent = flow === "signup"
      ? "Vamos criar seu acesso."
      : role === "owner" ? "Bem-vindo de volta." : "Acesse sua agenda.";
    $("authDescription").textContent = flow === "signup"
      ? "Cadastre sua conta de proprietário em poucos passos."
      : "Entre com o e-mail e a senha da sua conta.";
    $("authSubmit").textContent = flow === "signup" ? "Criar minha conta" : "Entrar";
    $("password").autocomplete = flow === "signup" ? "new-password" : "current-password";
    $("loginOnlyNote").hidden = flow !== "login";
    $("signupOnlyNote").hidden = flow !== "signup" || role !== "owner";
  }

  document.querySelectorAll("[data-role]").forEach((el) =>
    el.addEventListener("click", () => { role = el.dataset.role; render(); })
  );
  document.querySelectorAll("[data-flow]").forEach((el) =>
    el.addEventListener("click", () => { flow = el.dataset.flow; render(); })
  );

  if (!validConfig) {
    status("A conexão do Supabase ainda não está configurada. Avise o suporte da KWMT.", true);
  } else if (!window.supabase?.createClient) {
    status("Não foi possível carregar a conexão. Verifique a internet e recarregue a página.", true);
  } else {
    client = window.supabase.createClient(cfg.url, cfg.publishableKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    client.auth.getSession().then(({ data, error }) => {
      if (error) status(friendlyError(error), true);
      else if (data.session) status("Você já está conectado. O próximo passo é abrir seu painel KWMT.");
    });
  }

  $("authForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!client) {
      status("A conexão ainda não está disponível. Tente novamente mais tarde.", true);
      return;
    }
    const email = $("email").value.trim().toLowerCase();
    const password = $("password").value;
    const button = $("authSubmit");
    button.disabled = true;
    button.textContent = flow === "signup" ? "Criando conta…" : "Entrando…";
    try {
      if (flow === "signup") {
        if (role !== "owner") throw new Error("O cadastro inicial é feito pelo proprietário. O professor precisa receber um convite da escola.");
        const fullName = $("ownerName").value.trim();
        const schoolName = $("schoolName").value.trim();
        if (!fullName || !schoolName) throw new Error("Preencha seu nome e o nome da escola para continuar.");
        if (password.length < 8) throw new Error("Use uma senha com pelo menos 8 caracteres.");
        const { data, error } = await client.auth.signUp({
          email, password, options: { data: { full_name: fullName }, emailRedirectTo: "https://hidekiduarte.github.io/kwmt/login.html" }
        });
        if (error) throw error;
        if (data.session) {
          const { error: createError } = await client.rpc("create_school", {
            school_name: schoolName, operation_kind: "surf_school"
          });
          if (createError) throw createError;
          status("Conta criada e escola cadastrada! Seu primeiro acesso foi concluído.");
        } else {
          localStorage.setItem("kwmt_pending_school", JSON.stringify({
            name: schoolName, operation: "surf_school"
          }));
          status("Quase pronto! Enviamos um link de confirmação para seu e-mail. Confirme a mensagem e depois volte aqui em “Já tenho conta” para concluir o cadastro da escola.");
        }
      } else {
        const { data, error } = await client.auth.signInWithPassword({ email, password });
        if (error) throw error;
        const pending = role === "owner" ? localStorage.getItem("kwmt_pending_school") : null;
        if (pending) {
          const school = JSON.parse(pending);
          const { error: createError } = await client.rpc("create_school", {
            school_name: school.name, operation_kind: school.operation || "surf_school"
          });
          if (createError) throw createError;
          localStorage.removeItem("kwmt_pending_school");
          status("Pronto! Seu e-mail foi confirmado e sua escola foi cadastrada.");
        } else {
          const wantedRole = role === "owner" ? "owner" : "teacher";
          const { data: memberships, error: memberError } = await client
            .from("school_members").select("role,school_id")
            .eq("user_id", data.user.id).eq("role", wantedRole).eq("active", true);
          if (memberError) throw memberError;
          if (!memberships?.length) {
            throw new Error(role === "owner"
              ? "Esta conta ainda não está vinculada como proprietária. Se é seu primeiro cadastro, use “Primeiro acesso”."
              : "Esta conta ainda não recebeu um convite ativo de professor.");
          }
          status("Login confirmado! Sua conta está vinculada à KWMT.");
        }
      }
    } catch (error) {
      status(friendlyError(error), true);
    } finally {
      button.disabled = false;
      render();
    }
  });


  const resendButton = $("resendConfirmation");
  if (resendButton) {
    resendButton.addEventListener("click", async () => {
      if (!client) return status("A conexão ainda não está disponível.", true);
      const email = $("email").value.trim().toLowerCase();
      if (!email) return status("Digite seu e-mail antes de pedir outro link.", true);
      resendButton.disabled = true;
      try {
        const { error } = await client.auth.resend({
          type: "signup",
          email,
          options: { emailRedirectTo: "https://hidekiduarte.github.io/kwmt/login.html" }
        });
        if (error) throw error;
        status("Enviamos um novo link. Abra a mensagem mais recente do Supabase no seu e-mail.");
      } catch (error) {
        status(friendlyError(error), true);
      } finally {
        resendButton.disabled = false;
      }
    });
  }

  $("signOut").addEventListener("click", async () => {
    if (!client) return;
    const { error } = await client.auth.signOut();
    if (error) status(friendlyError(error), true);
    else status("Você saiu da sua conta.");
  });

  render();
})();
