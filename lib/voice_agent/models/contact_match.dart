class ContactMatch {
  final String id;
  final String name;
  final String phoneNumber;
  final String? label;

  ContactMatch({
    required this.id,
    required this.name,
    required this.phoneNumber,
    this.label,
  });

  factory ContactMatch.fromMap(Map<dynamic, dynamic> map) {
    return ContactMatch(
      id: map['id'].toString(),
      name: map['name']?.toString() ?? '',
      phoneNumber: map['phoneNumber']?.toString() ?? '',
      label: map['label']?.toString(),
    );
  }
}
