#! /bin/bash
# -*- encoding: UTF-8 -*-
#
# Сценарий для журналирования ресурсов заданного процесса (сервис на bash)
#
# (C) 2023 https://clearwayintegration.com
# Последнее обновление: 2023.04.25

# установка параметров по-умолчанию, если пользователь забыл указать их в "itclog.conf.sh"
itclog_defaults() {
  #CMD="postgres"   # имя контролируемого процесса
  CMD="itcsrvd"     # имя контролируемого процесса
  LOG1_T="60"       # период записи в "длинный бесконечный" лог [минут]
  LOG2_T="1"        # период записи в "оперативный ротируемый" лог [минут]
  LOG2_R="60"       # период ротации "оперативных" логов [минут]
  SLEEP="60"        # число секунд в минуте (если задать больше/меньше - логи будут обновляться реже/чаще)
  NAME=`basename "$0"`      # имя сценария ("itclog.sh")
  BNAME=`basename "$0" .sh` # базовое имя сценария ("itclog")
  PID_FILE="${BNAME}.pid"   # имя PID файла ("itclog.pid")
  LOG1_NAME="${BNAME}.csv"  # имя файла "длинного" лога ("itclog.log")
  #LOG2_BNAME="${BNAME}"    # базовая часть имени "оперативного" лога ("itclog")
  LOG2_EXT="csv"            # расширения "оперативных" логов
  DATETIME="+%Y.%m.%d-%H:%M:%S" # формат метки времени (аргументы для `date`)

  # следующая строка заголовка и аргументы для `ps` должны соответствовать друг-другу
  # кроме первого столбца LOG_HEADER, который обозначает метку времени (DateTime)
  LOG_HEADER="DateTime,PID,RSz,VSz,Mem,CPU,User,UpTime,Command" # строка заголовка CSV логов
  PS_FORMAT="h -o pid,rsz,vsz,%mem,%cpu,user,etime,comm --sort -rsz" # аргументы формата вывода `ps`
}

# отладочная печать конфигурации
fn_showcfg() {
  echo "CMD=\"$CMD\""
  echo "LOG1_T=$LOG1_T [sec]"
  echo "LOG2_T=$LOG2_T [sec]"
  echo "BNAME=\"$BNAME\""
  echo "PID_FILE=\"$PID_FILE\""
  echo "LOG1_NAME=\"$LOG1_NAME\""
  echo "LOG2_NAME=\"${LOG2_BNAME}.N.${LOG2_EXT}\" N=0..9"
  echo "PWD=\"`pwd`\""
}

# вывеси справку по применению скрипта
fn_usage() {
  echo "usage: $NAME {start|status|stop|restart|kill|clean}" >&2
  exit 1
}

# проверить не запущен ли уже сценарий в фоне
check_run() {
  if [ -f "$PID_FILE" ]
  then # PID файл существует
    RUN_PID=`cat "$PID_FILE"`
    if [ -z "$RUN_PID" ]
    then # PID файл пустой (авария!)
      echo "error: empty \"$PID_FILE\"; remove it"
      rm "$PID_FILE" # удалить PID файл 
      return 3
    fi

    # проверить запущен ли процесс с заданным PID
    PS_PID=`ps -p $RUN_PID -o pid=`
    if [ -z "$PS_PID" ]
    then # процесс с заданным PID не запущен (авария!)
      echo "error: bad PID in \"$PID_FILE\"; remove it"
      rm "$PID_FILE" # удалить PID файл
      return 2
    fi

    return 0 # сценарий запущен, PID верный
  else # PID файл не существует
    # проверить на всякий случай, а не запущены ли другие подобные процессы
    PS_PID=`ps -C "$NAME" -o pid=`
    if [ "$PS_PID" ]
    then
      PID_CNT=`echo "$PS_PID" | wc -l`
      if [ "$PID_CNT" -gt "1" ]
      then # какое-то количество подобных процессор запущено
        CNT=$(($PID_CNT - 1))
        echo "warning: no file "$PID_FILE" but $CNT process of $NAME run" >&2
      fi
    fi
   
    return 1 # PID файл отсутсвует - считаем, что сценарий НЕ запущен
  fi
}

# получить строки статуса в CSV форме
itclog_ps() {
  TIME=`date "$DATETIME"`
  ps -C "$CMD" $PS_FORMAT | while read LINE
  do
    OUT="$TIME"
    for COL in $LINE # FIXME тут можно вероятно без цикла использовать sed/awk
    do
      OUT+=",$COL"
    done
    echo "$OUT"
  done
}

# ротация "коротких" логов
itclog_rotate() {
  for i in `seq 8 -1 0` # 8...0
  do
    j=$(($i + 1))
    if [ -f "${LOG2_BNAME}.${i}.${LOG2_EXT}" ]
    then
      mv "${LOG2_BNAME}.${i}.${LOG2_EXT}" \
         "${LOG2_BNAME}.${j}.${LOG2_EXT}"
    fi
  done
  echo "$LOG_HEADER" > "${LOG2_BNAME}.0.${LOG2_EXT}"
}

# запускаемый в фоновом режиме процесс
itclog_background() {
  CNT1="1" # счетчик минут для обновления "длинного" лога
  CNT2="1" # счетчик минут для ротации логов
  CNT3="1" # счетчик минут для обновления "ротируемого" лога

  T0=`date +%s` # время в секундах c 1970-01-01 00:00:00 UTC

  while true # бесконечный цикл
  do
    T1=`date +%s`
    if [ "$T1" -ge "$T0" ] 
    then # прошло число секунд заданное в переменной $SLEEP (одна минута)
      T0=$(($T0 + $SLEEP))

      CNT1=$(($CNT1 - 1))
      if [ "$CNT1" -eq "0" ]
      then # запись в "динный" лог
        CNT1="$LOG1_T"
        [ -f "$LOG1_NAME" ] && itclog_ps >> "$LOG1_NAME"
      fi
      
      CNT2=$(($CNT2 - 1))
      if [ "$CNT2" -eq "0" ]
      then # ротация логов
        CNT2="$LOG2_R"
        itclog_rotate
      fi
      
      CNT3=$(($CNT3 - 1))
      if [ "$CNT3" -eq "0" ]
      then # запись в "короткий" лог
        CNT3="$LOG2_T"
        [ -f "${LOG2_BNAME}.0.${LOG2_EXT}" ] && \
          itclog_ps >> "${LOG2_BNAME}.0.${LOG2_EXT}"
      fi
    fi
    sleep 1 # одну секунды
  done
}

# запуск сценария как фонового процесса
fn_start() {
  if check_run
  then
    echo "warning: $NAME already run (PID=`cat "$PID_FILE"`); exit"
    return
  fi

  # вывести конфигурацию
  fn_showcfg

  # проверить имеется ли "длинный" лог
  if [ -f "$LOG1_NAME" ] && \
     [ "`head -n 1 "$LOG1_NAME" | wc -l`" != "0" ]
  then # файл присутствует и содержит не менее одной строки
    echo "info: file \"$LOG1_NAME\" exist; append it"
  else # файл отсутствует ИЛИ содержим одну неполную строку
    # создать "длинный" лог и сохранить в него заголовок
    echo "info: no file \"$LOG1_NAME\"; create it"
    echo "$LOG_HEADER" > "$LOG1_NAME"
  fi

  # запустить фоновый процесс и создать PID файл
  itclog_background >/dev/null 2>/dev/null &
  echo $! > "$PID_FILE"
  echo "start $NAME in background (PID=$!)"
}

# вывести статут сценария
fn_status() {
  if check_run
  then
    echo "$NAME is started (PID=`cat "$PID_FILE"`)"
  else
    echo "$NAME is not started (no \"$PID_FILE\")"
  fi
}

# остановить сценарий
fn_stop() {
  if check_run
  then
    RUN_PID=`cat "$PID_FILE"`
    if kill -9 "$RUN_PID"
    then
      if rm "$PID_FILE"
      then
        echo "stop $NAME (PID=$RUN_PID)"
      else
        echo "error: can't remove \"$PID_FILE\"" >&2
      fi
    else
      echo "error: can't kill PID=$RUN_PID" >&2
    fi
  else
    echo "warning: $NAME is not started (no \"$PID_FILE\")" >&2
  fi
}

# убить все запущенные сценарии в системе данного типа
fn_kill() {
  # убить все процессы по одному (альтернатива killall -9 "$NAME")
  PS_PID=`ps -C "$NAME" -o pid=`
  if [ "$PS_PID" ]
  then
    PID_CNT=`echo "$PS_PID" | wc -l`
    if [ "$PID_CNT" -gt "1" ]
    then # какое-то количество подобных процессор запущено, убить их всех
      CNT=$(($PID_CNT - 1))
      echo "$NAME run $CNT times; kill it`test $CNT -gt 1 && echo -n " all"`"
      for P_ID in $PS_PID
      do
        [ "$P_ID" -eq "$$" ] && continue # не убивать самого себя
        COMMAND=`ps -p $P_ID -o cmd=`
        kill -9 $P_ID && echo "kill PID=$P_ID ($COMMAND)" \
                      || echo "error: can't kill PID=$_PID ($COMMAND); skip" >&2
      done
    else
      echo "no any $NAME child process; do anything"
    fi
  fi

  if [ -f "$PID_FILE" ]
  then # PID файл существует, удалить его
    echo "remove \"$PID_FILE\""
    rm "$PID_FILE"
  fi
}

# удалить все логи (перезапустить сценарий, если он был запущен)
fn_clean() {
  WAS_STARTED=""
  check_run && fn_stop && WAS_STARTED="YES"

  [ -f "$LOG1_NAME" ] && rm "$LOG1_NAME" && echo "remove \"$LOG1_NAME\""

  for i in `seq 0 9`
  do
    [ -f "${LOG2_BNAME}.${i}.${LOG2_EXT}" ] && \
      rm "${LOG2_BNAME}.${i}.${LOG2_EXT}" && \
      echo "remove \"${LOG2_BNAME}.${i}.${LOG2_EXT}\""
  done

  [ "$WAS_STARTED" ] && fn_start
}

OLDPWD=`pwd` # запомнить текущий каталог
WDIR=`dirname $0` # каталог, где размещается сценарий
cd "$WDIR" # перейти в каталог сценария

# установка параметров по-умолчанию
itclog_defaults

# загрузить конфигурационный файл
[ -f "itclog.conf.sh" ] && source "itclog.conf.sh"

ACTION="$1" # заданное действие (start|status|stop|restart|kill|clean)

# разобрать опции командной строки
case "$ACTION" in
  start)   fn_start  ;;
  status)  fn_status ;;
  stop)    fn_stop   ;;
  restart) fn_stop && fn_start ;;
  kill)    fn_kill   ;;
  clean)   fn_clean  ;;
  *)       fn_usage  ;;
esac

cd "$OLDPWD" # вернуться в каталог, из которого сценарий был запущен

### end of "itclog.sh" file ###

