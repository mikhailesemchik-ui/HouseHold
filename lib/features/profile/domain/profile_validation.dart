const int displayNameMaxLength = 50;

/// Returns an error message if [value] is not a valid display name, or null.
String? validateDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'Name cannot be blank.';
  if (trimmed.length > displayNameMaxLength) return 'Name is too long.';
  return null;
}
