class MusicFolder {
  static const unsortedId = 'unsorted';

  final String id;
  String name;

  MusicFolder({required this.id, required this.name});

  bool get isUnsorted => id == unsortedId;

  factory MusicFolder.fromJson(Map<String, dynamic> json) =>
      MusicFolder(id: json['id'] as String, name: json['name'] as String);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}
