/// sqflite 行值与实体字段的基础转换（bool 存 INTEGER，时间存毫秒）。
library;

int boolToInt(bool v) => v ? 1 : 0;

bool boolFromInt(Object? v) => v == 1 || v == '1' || v == true;

int? boolToNullableInt(bool? v) => v == null ? null : (v ? 1 : 0);

bool? boolFromNullableInt(Object? v) =>
    v == null ? null : (v == 1 || v == '1' || v == true);

int nowMs() => DateTime.now().millisecondsSinceEpoch;
