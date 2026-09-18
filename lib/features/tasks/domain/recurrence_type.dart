enum RecurrenceType {
  none,
  daily,
  weekly;

  /// Parses the database string value. Unknown values fall back to [none].
  static RecurrenceType parse(String s) => switch (s) {
    'daily' => daily,
    'weekly' => weekly,
    _ => none,
  };

  /// The string stored in the database.
  String get value => name;

  String get label => switch (this) {
    none => 'Does not repeat',
    daily => 'Daily',
    weekly => 'Weekly',
  };
}
