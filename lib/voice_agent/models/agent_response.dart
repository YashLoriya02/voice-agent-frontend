class AgentResponse {
  final bool success;
  final String? type;
  final String? tool;
  final Map<String, dynamic> arguments;
  final String? message;

  AgentResponse({
    required this.success,
    this.type,
    this.tool,
    this.arguments = const {},
    this.message,
  });

  factory AgentResponse.fromJson(Map<String, dynamic> json) {
    final rawArguments = json['arguments'];

    return AgentResponse(
      success: json['success'] == true,
      type: json['type']?.toString(),
      tool: json['tool']?.toString(),
      message: json['message']?.toString(),
      arguments: rawArguments is Map
          ? Map<String, dynamic>.from(rawArguments)
          : {},
    );
  }
}
