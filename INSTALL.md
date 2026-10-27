# Установка OpenCombkeeper 0.1.0

## 1. Построить план

На компьютере с Python 3.10+:

```sh
python3 -m pip install -e .
opencombkeeper plan \
  --catalog data/comb-catalog.json \
  --config examples/mcskill.json \
  --output plan.json \
  --lua-output plan.lua
```

До запуска проверьте `startingShortages`, `unreachableCombs` и список ручных
задач в `plan.json`.

## 2. Установить файлы OpenOS

В `/home/.opencombkeeper/` нужны:

- сгенерированный `plan.lua`;
- `src/executor.lua`;
- собственный `hardware.lua` по контракту `src/hardware.example.lua`.

Точку входа `opencombkeeper.lua` можно положить в `/home/bin/`.

## 3. Привязать оборудование

Адаптер обязан проверять фактический результат каждого переноса и атомарно
сохранять состояние. Для `prepare_manual_mutation` он загружает родителей в
продвинутый мутатрон; игрок выбирает результат и возвращает матку в отдельный
контейнер. Для обычной мутации адаптер возвращает распознанный вид матки либо
`genetic_waste`.

Сначала выполните `opencombkeeper status`, затем пробный `run` на одной
неценной линии. Полный запуск допустим только после проверки адресов, сторон и
слотов непосредственно на сервере.
