class PushEvent {
  final int localQueueId;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, dynamic> payload;
  final DateTime clientTimestamp;

  PushEvent({
    required this.localQueueId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.clientTimestamp,
  });

  factory PushEvent.fromJson(Map<String, dynamic> json) => PushEvent(
        localQueueId: json['localQueueId'] as int,
        entityType: json['entityType'] as String,
        entityId: json['entityId'] as String,
        operation: json['operation'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        clientTimestamp: DateTime.parse(json['clientTimestamp'] as String),
      );
}

class SyncEvent {
  final int id;
  final String deviceId;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, dynamic> payload;
  final DateTime serverTimestamp;

  SyncEvent({
    required this.id,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.serverTimestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'entityType': entityType,
        'entityId': entityId,
        'operation': operation,
        'payload': payload,
        'serverTimestamp': serverTimestamp.toUtc().toIso8601String(),
      };
}

class ConflictResult {
  final int localQueueId;
  final String reason;
  final Map<String, dynamic>? serverPayload;

  ConflictResult({
    required this.localQueueId,
    required this.reason,
    this.serverPayload,
  });

  Map<String, dynamic> toJson() => {
        'localQueueId': localQueueId,
        'reason': reason,
        'serverPayload': serverPayload,
      };
}
