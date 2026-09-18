# Описание сути лабораторной работы

В рамках лабораторной нужно имитировать контейнеризацию, по факту создав свой Docker. Необходимо запустить процесс без изоляции, потом навесить на него namespaces, ограничения ресусрсов и урезание прав. Все команды надо собрать в один скрипт (это будет Docker), сравню свой Docker с настоящим запуском `docker run`.

# Ход работы
## Подготовка
До сегодняшнего дня я был активным пользователем Windows, иногда заходил на Linux: был пользователем Ubuntu, Arch. Чтобы не делить диск, купил новый ssd диск, установил его в пк и загрузил Ubuntu, решил не усложнять себе жизнь. Установил необходимые утилиты для работы.

## Часть 0 - свой сервис
Написал (сгенерировал) свой сервис на Go с 3 эндпоинтами : 
- `GET /health` — возвращает `ok`;
- `GET /eat?mb=N` — выделяет N мегабайт памяти и держит их;
- `GET /burn` — нагружает одно ядро CPU в бесконечном цикле.

## Часть 1 - прямой запуск
запустил сервис напрямую без ограничений. `/health` возвращает `ok`
![alt text](image.png)

запустил `ps` и получил точку отсчета, на которую в дальнейшем смогу опираться. 
``` bash
ps -p 10204 -o pid, ppid,user,cmd
    PID    PPID USER     CMD
  10204    6627 tim      ./api
```
![alt text](image-2.png)

запустил `ls -l /proc/$(pgrep api)/ns/` и `ls -l /proc/$$/ns/`
``` bash
pgrep -a api
ls -l /proc/$(pgrep api)/ns/ # namespace сервиса
ls -l /proc/$$/ns/ # namespace моей shell
10204 ./api
total 0
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 mnt -> 'mnt:[4026531832]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 net -> 'net:[4026531833]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 pid_for_children -> 'pid:[4026531836]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 time -> 'time:[4026531834]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 time_for_children -> 'time:[4026531834]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 user -> 'user:[4026531837]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:17 uts -> 'uts:[4026531838]'
total 0
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 mnt -> 'mnt:[4026531832]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 net -> 'net:[4026531833]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 pid_for_children -> 'pid:[4026531836]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 time -> 'time:[4026531834]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 time_for_children -> 'time:[4026531834]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 user -> 'user:[4026531837]'
lrwxrwxrwx 1 tim tim 0 Sep 18 09:16 uts -> 'uts:[4026531838]'
```
![alt text](image-1.png)
сравнил полученные результаты для понимания, что это неизолированный процесс на данный момент. Такой выовд сделал из того, что у одних и тех же namespace сервиса и моей shell одни и теже значения. 