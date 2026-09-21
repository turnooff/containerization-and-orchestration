#include <errno.h>
#include <seccomp.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s PROGRAM [ARGUMENTS...]\n", argv[0]);
        return 2;
    }

    // 1. Запретить получение дополнительных привилегий при exec.
    if (prctl(PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L) == -1) {
        perror("PR_SET_NO_NEW_PRIVS");
        return 1;
    }

    // 2. Политика по умолчанию: разрешать системные вызовы.
    scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ALLOW);
    if (filter == NULL) {
        fprintf(stderr, "seccomp_init: cannot create filter\n");
        return 1;
    }

    // 3. Запретить оба способа создания каталога, независимо от пути и прав.
    int rc = seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM),
                              SCMP_SYS(mkdir), 0);
    if (rc < 0) {
        fprintf(stderr, "seccomp_rule_add mkdir: %s\n", strerror(-rc));
        seccomp_release(filter);
        return 1;
    }

    rc = seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM),
                          SCMP_SYS(mkdirat), 0);
    if (rc < 0) {
        fprintf(stderr, "seccomp_rule_add mkdirat: %s\n", strerror(-rc));
        seccomp_release(filter);
        return 1;
    }

    // 4. Передать фильтр ядру. При ошибке целевую программу не запускать.
    rc = seccomp_load(filter);
    seccomp_release(filter); // Освобождаем память библиотеки, фильтр ядра остаётся.
    if (rc < 0) {
        fprintf(stderr, "seccomp_load: %s\n", strerror(-rc));
        return 1;
    }

    // 5. Заменить launcher целевой программой. Фильтр сохраняется.
    execvp(argv[1], &argv[1]);

    // Успешный execvp сюда не возвращается.
    int exec_error = errno;
    fprintf(stderr, "execvp %s: %s\n", argv[1], strerror(exec_error));
    return exec_error == ENOENT ? 127 : 126;
}
