/* KWMT — integração do agendamento com Supabase STAGING.
 * O app.js continua responsável pelas áreas ainda locais; este módulo assume
 * somente os selects e o envio do formulário schoolLessonForm.
 */
(() => {
  "use strict";
  const cfg = window.KWMT_SUPABASE_CONFIG || {};
  const money = value => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(value) || 0);
  const toast = message => {
    const el = document.getElementById("toast");
    if (el) { el.textContent = message; el.style.display = "block"; }
  };
  if (!cfg.url || !cfg.publishableKey || !window.supabase?.createClient) {
    console.error("[KWMT] Supabase não inicializado.");
    return;
  }
  const client = window.supabase.createClient(cfg.url, cfg.publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
  const fail = (message, cause) => { const e = new Error(message); e.cause = cause; throw e; };
  function friendlyError(error) {
    const m = String(error?.message || "");
    if (error?.code === "23P01" || /exclusion constraint|overlap/i.test(m)) return "Esse professor já tem uma aula nesse horário. Escolha outro horário.";
    if (/expired/i.test(m)) return "Este pacote está vencido. Selecione outro pacote válido.";
    if (/package.*not active|cancelled, expired or completed package/i.test(m)) return "Este pacote não está ativo para novos agendamentos.";
    if (/does not belong to the lesson student/i.test(m)) return "O pacote selecionado não pertence a este aluno.";
    if (/not authorized|row-level security|permission denied/i.test(m)) return "Sua conta não tem permissão para realizar esta operação.";
    return m || "Não foi possível concluir a operação. Tente novamente.";
  }
  async function requireOwnerSchool() {
    const { data, error } = await client.auth.getSession();
    if (error) fail("Não foi possível verificar sua sessão.", error);
    const user = data.session?.user;
    if (!user) fail("Sua sessão expirou. Entre novamente.");
    const result = await client.from("school_members").select("school_id")
      .eq("user_id", user.id).eq("role", "owner").eq("active", true).limit(2);
    if (result.error) fail(friendlyError(result.error), result.error);
    if (!result.data?.length) fail("Sua conta não está vinculada como proprietária de uma escola.");
    if (result.data.length > 1) fail("Sua conta administra mais de uma escola. A seleção precisa ser definida antes de agendar.");
    return { user, schoolId: result.data[0].school_id };
  }
  async function loadStudents() {
    const { schoolId } = await requireOwnerSchool();
    const { data, error } = await client.from("students").select("id,name").eq("school_id", schoolId).order("name");
    if (error) fail(friendlyError(error), error);
    return data || [];
  }
  async function loadTeachers() {
    const { schoolId } = await requireOwnerSchool();
    const { data, error } = await client.from("teachers").select("id,name").eq("school_id", schoolId).eq("active", true).order("name");
    if (error) fail(friendlyError(error), error);
    return data || [];
  }
  async function loadPackages(studentId) {
    if (!studentId) return [];
    const { schoolId } = await requireOwnerSchool();
    const now = new Date().toISOString();
    const { data, error } = await client.from("student_packages")
      .select("id,student_id,lessons_purchased,lessons_used,expires_at,status,package_offers(name)")
      .eq("school_id", schoolId).eq("student_id", studentId).eq("status", "active")
      .or(`expires_at.is.null,expires_at.gt.${now}`).order("purchased_at", { ascending: false });
    if (error) fail(friendlyError(error), error);
    return (data || []).filter(p => Number(p.lessons_used || 0) < Number(p.lessons_purchased));
  }
  function localDateTimeToIso(date, time) {
    if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date || "") || !/^\\d{2}:\\d{2}$/.test(time || "")) fail("Informe uma data e um horário válidos.");
    const value = new Date(`${date}T${time}:00`);
    if (Number.isNaN(value.getTime())) fail("Data ou horário inválido.");
    return value.toISOString();
  }
  async function schedulePackageLesson({ studentId, teacherId, packageId, date, time }) {
    if (!studentId || !teacherId || !packageId) fail("Selecione aluno, professor e pacote.");
    const { schoolId } = await requireOwnerSchool();
    const startsAt = localDateTimeToIso(date, time);
    const endsAt = new Date(new Date(startsAt).getTime() + 60 * 60000).toISOString();
    const { data: pkg, error: packageError } = await client.from("student_packages")
      .select("id,student_id,status,expires_at,lessons_purchased,lessons_used")
      .eq("school_id", schoolId).eq("id", packageId).eq("student_id", studentId).maybeSingle();
    if (packageError) fail(friendlyError(packageError), packageError);
    if (!pkg || pkg.status !== "active") fail("O pacote não está ativo ou não pertence a este aluno.");
    if (pkg.expires_at && new Date(endsAt) > new Date(pkg.expires_at)) fail("A aula termina depois da validade do pacote.");
    if (Number(pkg.lessons_used || 0) >= Number(pkg.lessons_purchased)) fail("Este pacote não tem aulas disponíveis.");
    const { data, error } = await client.from("lessons").insert({
      school_id: schoolId, student_id: studentId, teacher_id: teacherId,
      student_package_id: packageId, starts_at: startsAt, ends_at: endsAt, status: "scheduled"
    }).select("id,student_id,teacher_id,student_package_id,starts_at,ends_at,status").single();
    if (error) fail(friendlyError(error), error);
    return data;
  }
  async function confirmAttendance(lessonId) {
    if (!lessonId) fail("Aula não identificada.");
    const { error } = await client.rpc("confirm_lesson_attendance", { target_lesson: lessonId });
    if (error) fail(friendlyError(error), error);
    return true;
  }
  window.KWMTLessons = Object.freeze({ loadStudents, loadTeachers, loadPackages, schedulePackageLesson, confirmAttendance, createStudentPackage, refreshPackageList, friendlyError });

  async function createStudentPackage({ studentName, unitPrice, lessonCount, isPaid, paymentMethod, purchaseDate }) {
    const { data, error } = await client.rpc("create_student_package", {
      student_name: studentName,
      unit_price: Number(unitPrice),
      lesson_count: Number(lessonCount),
      is_paid: Boolean(isPaid),
      payment_method: isPaid ? paymentMethod : null,
      purchase_date: purchaseDate
    });
    if (error) fail(friendlyError(error), error);
    return data;
  }
  async function refreshPackageList() {
    const { schoolId } = await requireOwnerSchool();
    const { data, error } = await client.from("student_packages")
      .select("id,lessons_purchased,lessons_used,contracted_amount,purchased_at,status,students(name),package_offers(name)")
      .eq("school_id", schoolId).order("purchased_at", { ascending: false });
    if (error) fail(friendlyError(error), error);
    const target = $("packageList");
    if (!target) return;
    target.innerHTML = (data || []).length ? data.map(p => {
      const remaining = Number(p.lessons_purchased) - Number(p.lessons_used || 0);
      const studentName = p.students?.name || "Aluno";
      const date = p.purchased_at ? new Date(p.purchased_at).toLocaleDateString("pt-BR") : "";
      return `<div class="item"><strong>${studentName} <span class="pill ${remaining <= 1 ? "bad" : remaining <= 5 ? "warn" : "good"}">${remaining} restantes</span></strong><div class="sub">${p.package_offers?.name || "Pacote"} · ${money(p.contracted_amount)} · ${date}<br>${Number(p.lessons_used || 0)}/${p.lessons_purchased} utilizadas · ${p.status === "active" ? "Ativo" : p.status}</div></div>`;
    }).join("") : '<div class="empty">Nenhum pacote cadastrado no banco.</div>';
  }

  const $ = id => document.getElementById(id);
  const makeOption = (value, label) => { const o = document.createElement("option"); o.value = value; o.textContent = label; return o; };
  async function connectForm() {
    const form = $("schoolLessonForm"), student = $("schoolStudent"), pack = $("schoolPackage"), teacher = $("teacher");
    if (!form || !student || !pack || !teacher) return;
    const setOptions = (select, placeholder, rows, label) => {
      select.replaceChildren(makeOption("", placeholder));
      rows.forEach(row => select.append(makeOption(row.id, label(row))));
    };

    const packageForm = $("packageForm");
    if (packageForm) {
      const paidSelect = $("packagePaid"), methodSelect = $("packagePaymentMethod");
      const syncPaymentMethod = () => { if (methodSelect) methodSelect.disabled = paidSelect.value !== "paid"; };
      if (paidSelect) { paidSelect.addEventListener("change", syncPaymentMethod); syncPaymentMethod(); }
      packageForm.addEventListener("submit", async event => {
        event.preventDefault();
        event.stopImmediatePropagation();
        const button = packageForm.querySelector('button[type="submit"],button:not([type])');
        if (button) { button.disabled = true; button.textContent = "Salvando no banco..."; }
        try {
          const result = await createStudentPackage({
            studentName: $("student").value.trim(),
            unitPrice: $("unitPrice").value,
            lessonCount: $("packageLessonCount").value,
            isPaid: $("packagePaid").value === "paid",
            paymentMethod: $("packagePaymentMethod")?.value || null,
            purchaseDate: $("packageDate").value
          });
          toast("Aluno e pacote cadastrados no Supabase. Código: " + result.student_package_id.slice(0, 8));
          packageForm.reset();
          $("packageDate").value = new Date().toLocaleDateString("en-CA");
          syncPaymentMethod();
          await refreshPackageList();
          const students = await loadStudents();
          const studentSelect = $("schoolStudent");
          if (studentSelect) {
            studentSelect.replaceChildren(makeOption("", "Selecione o aluno"));
            students.forEach(s => studentSelect.append(makeOption(s.id, s.name)));
            studentSelect.value = result.student_id;
            studentSelect.dispatchEvent(new Event("change"));
          }
        } catch (error) {
          console.error("[KWMT] Falha ao cadastrar aluno/pacote:", error.cause || error);
          toast(friendlyError(error));
        } finally { if (button) { button.disabled = false; button.textContent = "Criar pacote"; } }
      }, true);
    }
    try {
      const [students, teachers] = await Promise.all([loadStudents(), loadTeachers()]);
      setOptions(student, students.length ? "Selecione o aluno" : "Cadastre alunos no banco", students, x => x.name);
      setOptions(teacher, teachers.length ? "Selecione o professor" : "Cadastre professores no banco", teachers, x => x.name);
      setOptions(pack, "Selecione primeiro o aluno", [], () => "");
      await refreshPackageList();
    } catch (error) {
      console.error("[KWMT] Falha ao carregar dados do agendamento:", error);
      toast(friendlyError(error));
    }
    student.addEventListener("change", async () => {
      pack.disabled = true;
      pack.replaceChildren(makeOption("", "Carregando pacotes..."));
      try {
        const packages = await loadPackages(student.value);
        pack.replaceChildren(makeOption("", packages.length ? "Selecione o pacote" : "Nenhum pacote válido disponível"));
        packages.forEach(p => {
          const remaining = Number(p.lessons_purchased) - Number(p.lessons_used || 0);
          pack.append(makeOption(p.id, `${p.package_offers?.name || "Pacote"} · ${remaining} aula(s) restantes`));
        });
      } catch (error) { pack.replaceChildren(makeOption("", friendlyError(error))); }
      finally { pack.disabled = false; }
    });
    // Capture impede o listener antigo do app.js de gravar a mesma aula no localStorage.
    form.addEventListener("submit", async event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      const button = form.querySelector('button[type="submit"],button:not([type])');
      if (button) { button.disabled = true; button.textContent = "Agendando..."; }
      try {
        const lesson = await schedulePackageLesson({ studentId: student.value, teacherId: teacher.value,
          packageId: pack.value, date: $("schoolDate").value, time: $("schoolTime").value });
        toast("Aula agendada no Supabase staging. Código: " + lesson.id.slice(0, 8));
        form.reset();
        $("schoolDate").value = new Date().toLocaleDateString("en-CA");
        pack.replaceChildren(makeOption("", "Selecione primeiro o aluno"));
      } catch (error) {
        console.error("[KWMT] Agendamento recusado:", error.cause || error);
        toast(friendlyError(error));
      } finally { if (button) { button.disabled = false; button.textContent = "Agendar aula de 1 hora"; } }
    }, true);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", connectForm, { once: true });
  else connectForm();
})();
