/* KWMT — agendamento da Escolinha via Supabase
 * Módulo isolado para a branch redesign-japones.
 * Ainda não substitui o app.js nem é carregado pelo index.html.
 * Requer supabase-js UMD e supabase-config.js carregados antes deste arquivo.
 */
(() => {
  "use strict";

  const config = window.KWMT_SUPABASE_CONFIG || {};
  if (!config.url || !config.publishableKey || !window.supabase?.createClient) {
    console.error("[KWMT] Configuração ou biblioteca Supabase indisponível.");
    return;
  }

  // Usa a mesma persistência de sessão do auth.js. O JWT do usuário é enviado
  // automaticamente pelo cliente e as políticas RLS continuam sendo aplicadas.
  const client = window.supabase.createClient(config.url, config.publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  const fail = (message, cause) => {
    const error = new Error(message);
    error.cause = cause;
    throw error;
  };

  function friendlyError(error) {
    const message = String(error?.message || "");
    const code = error?.code;

    if (code === "23P01" || /exclusion constraint|overlap/i.test(message)) {
      return "Esse professor já tem uma aula nesse horário. Escolha outro horário.";
    }
    if (/expired package|expired validity|expired/i.test(message)) {
      return "Este pacote está vencido. Selecione outro pacote válido.";
    }
    if (/cancelled, expired or completed package|package.*not active/i.test(message)) {
      return "Este pacote não está ativo e não pode receber novos agendamentos.";
    }
    if (/does not belong to the lesson student/i.test(message)) {
      return "O pacote selecionado não pertence a este aluno.";
    }
    if (/future or ongoing scheduled lesson/i.test(message)) {
      return "Não é possível cancelar o pacote enquanto houver aulas futuras. Cancele ou reagende essas aulas primeiro.";
    }
    if (/not authorized|row-level security|permission denied/i.test(message)) {
      return "Sua conta não tem permissão para realizar esta operação.";
    }
    if (/duplicate key/i.test(message)) {
      return "Este registro já existe. Atualize a tela e tente novamente.";
    }
    return message || "Não foi possível concluir a operação. Tente novamente.";
  }

  async function requireOwnerSchool() {
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError) fail("Não foi possível verificar sua sessão.", sessionError);
    const user = sessionData.session?.user;
    if (!user) fail("Sua sessão expirou. Entre novamente.");

    const { data: memberships, error } = await client
      .from("school_members")
      .select("school_id")
      .eq("user_id", user.id)
      .eq("role", "owner")
      .eq("active", true)
      .limit(2);

    if (error) fail(friendlyError(error), error);
    if (!memberships?.length) fail("Sua conta não está vinculada como proprietária de uma escola.");
    if (memberships.length > 1) fail("Sua conta administra mais de uma escola. A seleção de escola precisa ser definida antes de agendar.");

    return { user, schoolId: memberships[0].school_id };
  }

  async function loadStudents() {
    const { schoolId } = await requireOwnerSchool();
    const { data, error } = await client
      .from("students")
      .select("id, name")
      .eq("school_id", schoolId)
      .order("name");
    if (error) fail(friendlyError(error), error);
    return data || [];
  }

  async function loadActiveTeachers() {
    const { schoolId } = await requireOwnerSchool();
    const { data, error } = await client
      .from("teachers")
      .select("id, name")
      .eq("school_id", schoolId)
      .eq("active", true)
      .order("name");
    if (error) fail(friendlyError(error), error);
    return data || [];
  }

  async function loadActivePackages(studentId) {
    if (!studentId) return [];
    const { schoolId } = await requireOwnerSchool();
    const now = new Date().toISOString();
    const { data, error } = await client
      .from("student_packages")
      .select("id, student_id, lessons_purchased, lessons_used, expires_at, status, package_offers(name)")
      .eq("school_id", schoolId)
      .eq("student_id", studentId)
      .eq("status", "active")
      .or(`expires_at.is.null,expires_at.gt.${now}`)
      .order("purchased_at", { ascending: false });

    if (error) fail(friendlyError(error), error);
    return (data || []).filter(pkg => pkg.lessons_used < pkg.lessons_purchased);
  }

  // Converte data/hora local do navegador para ISO com offset UTC correto.
  // O usuário escolhe o horário local da escola; não concatenamos "Z" manualmente.
  function localDateTimeToIso(date, time) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date || "") || !/^\d{2}:\d{2}$/.test(time || "")) {
      fail("Informe uma data e um horário válidos.");
    }
    const local = new Date(`${date}T${time}:00`);
    if (Number.isNaN(local.getTime())) fail("Data ou horário inválido.");
    return local.toISOString();
  }

  async function schedulePackageLesson({ studentId, teacherId, packageId, date, time, durationMinutes = 60 }) {
    if (!studentId || !teacherId || !packageId) fail("Selecione aluno, professor e pacote.");
    if (!Number.isInteger(durationMinutes) || durationMinutes <= 0) fail("A duração da aula é inválida.");

    const { user, schoolId } = await requireOwnerSchool();
    const startsAt = localDateTimeToIso(date, time);
    const endsAt = new Date(new Date(startsAt).getTime() + durationMinutes * 60000).toISOString();

    // Revalidação no cliente melhora o feedback; as triggers e constraints do
    // PostgreSQL continuam sendo a autoridade final contra corrida e fraude.
    const { data: pkg, error: packageError } = await client
      .from("student_packages")
      .select("id, student_id, status, expires_at, lessons_purchased, lessons_used")
      .eq("school_id", schoolId)
      .eq("id", packageId)
      .eq("student_id", studentId)
      .maybeSingle();

    if (packageError) fail(friendlyError(packageError), packageError);
    if (!pkg || pkg.status !== "active") fail("O pacote não está ativo ou não pertence a este aluno.");
    if (pkg.expires_at && new Date(pkg.expires_at).getTime() <= Date.now()) {
      fail("Este pacote está vencido. Selecione outro pacote válido.");
    }
    if (pkg.lessons_used >= pkg.lessons_purchased) fail("Este pacote não tem aulas disponíveis.");

    const { data, error } = await client
      .from("lessons")
      .insert({
        school_id: schoolId,
        student_id: studentId,
        teacher_id: teacherId,
        student_package_id: packageId,
        starts_at: startsAt,
        ends_at: endsAt,
        status: "scheduled"
      })
      .select("id, student_id, teacher_id, student_package_id, starts_at, ends_at, status")
      .single();

    if (error) fail(friendlyError(error), error);
    return data;
  }

  // A presença é confirmada somente pela RPC protegida do banco.
  async function confirmAttendance(lessonId) {
    if (!lessonId) fail("Aula não identificada.");
    const { error } = await client.rpc("confirm_lesson_attendance", {
      target_lesson: lessonId
    });
    if (error) fail(friendlyError(error), error);
    return true;
  }

  window.KWMTLessons = Object.freeze({
    loadStudents,
    loadActiveTeachers,
    loadActivePackages,
    schedulePackageLesson,
    confirmAttendance,
    friendlyError
  });
})();
