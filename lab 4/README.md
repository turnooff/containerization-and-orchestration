Часть 0

Написала небольшую программу на го. Все что она делает - занимает место в памяти (по умолчанию 64 Мб), и занимает примерно 50% CPU
Проверка:
docker run -d --rm --name lab4-batch \
  --cpus=0.5 \
  --memory=256m \
  -e MEMORY_MIB=64 \
  localhost:5001/shop-batch:1.0.0
![alt text](image.png)

Часть 1: два стула

Итак, есть два стула, на одном podAntiAffinity, а на другом topologySpreadConstraints.
podAntiAffinity такой злой чел, негативный, соседей не любит: если у нас две реплики на двух нодах, то третью реплику он никуда не пустит, и она останется висеть в состоянии pending. Но в мягком режиме ему можно сказать "эээ пусти переночевать по братски" - в таком случае планировщик старается разнести поды, но может разместить их и вместе
topologySpreadConstraints ровный пацанчик - старается поддерживать равномерность распределения подов. За базар отвечает, если сказано перекос между зонами не больше одного пода, значит все по красоте сделает - две реплики на одной ноде, одна на другой.

В качестве основного механизма решила выбрать topologySpreadConstraints, чтобы равномерно распределять поды. Файл values.yaml взят полностью из 3 лабы.

теперь в нем добавилось поле placement

api:
  replicas: 3
  placement:
    mode: topologySpreadConstraints
    topologySpreadConstraints:
      maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/component: api

тут maxSkew - допустимая разница между нодами в количестве подов,
topologyKey: kubernetes.io/hostname - распределение между нодами,
whenUnsatisfiable: DoNotSchedule — под ждёт, если размещение нарушит правило,
labelSelector учитывает поды api

Можно было бы использовать и podAntiAffinity с мягким режимом, но я побоялась что если при необходимости он может распределять поды 2 к 1, то не исключена ситуация, что он разместит все 3 реплики на одной ноде, а такого нам не хотелось бы

На всякий случай проверяю что чарт собирается без ошибок:
helm lint "lab 4/chart"
результат:
1 chart(s) linted, 0 chart(s) failed
как проверить правильность настроек я хэ зэ, поэтому удалю нафиг это наверное.

## Часть 2: в тесноте и в обиде

Создам кластер с одной работающей нодой и одной управляющей. (см kind-config.yaml)

kind create cluster \
  --name lab4 \
  --config "lab 4/kind-config.yaml" \
  --wait 3m

(забавно что с первого раза ничего естественно не запустилось и ломалось на последнем этапе:
 ✗ Joining worker nodes 🚜 
Deleted nodes: ["lab4-worker" "lab4-control-plane"]
ERROR: failed to create cluster: failed to join node with kubeadm: command "docker exec --privilegedlab4-worker kubeadm join --config /kind/kubeadm.conf --v=6" failed with error: exit status 1
после того как я сделала буквально НИЧЕГО и попробовала еще раз, все заработало
Ну что за магия )
Проверяем как там наши поды:
![alt text](image-1.png)

Поды замечательно, а значит установлю оператор CloudNativePG, и добавлю его в наш кластер, потому что он же использовался и в 3 лабе.
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --kube-context kind-lab4 \
  --namespace cnpg-system \
  --create-namespace \
  --wait \
  --timeout 5m
После этого скачала Kyverno и настроила гвардрейлы, чтобы синхронизироваться с 3 лабой

(хаха гвардрейлы такое смешное слово, я читаю его каждый раз как Гвардиола, что говорит о том, что мне стоило меньше смотреть футбол этим летом)

Ладно, хиханьки да хаханьки закончились, поэтому собираю бразы api и worker, а затем загружаю их вместе с batch в кластер.
docker build \
  -f "lab 3/app/api.Dockerfile" \
  -t localhost:5001/shop-api:1.0.4 \
  "lab 3/app"
docker build \
  -f "lab 3/app/worker.Dockerfile" \
  -t localhost:5001/shop-worker:1.0.0 \
  "lab 3/app"
kind load docker-image \
  localhost:5001/shop-api:1.0.4 \
  localhost:5001/shop-worker:1.0.0 \
  localhost:5001/shop-batch:1.0.0 \
  --name lab4
В консоли после этого мне выводилось очень много букв, но как правило они означали успешный успех

Потом я хз вообще что сделала, что-то очень странное и сложное, допишу потом

Главный вопрос - а для чего нужны были все эти телодвижения?