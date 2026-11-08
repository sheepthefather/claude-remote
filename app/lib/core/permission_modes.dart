class PermissionModeInfo {
  const PermissionModeInfo({
    required this.value,
    required this.label,
    required this.description,
    this.dangerous = false,
  });

  final String value;
  final String label;
  final String description;
  final bool dangerous;
}

const permissionModeInfos = <PermissionModeInfo>[
  PermissionModeInfo(
    value: 'default',
    label: 'Manual',
    description: '危险操作逐次推到手机确认',
  ),
  PermissionModeInfo(
    value: 'plan',
    label: 'Plan',
    description: '只读调研，不修改文件、不执行有副作用的命令',
  ),
  PermissionModeInfo(
    value: 'acceptEdits',
    label: 'Accept Edits',
    description: '自动批准 Edit / Write，Bash 等仍会询问',
  ),
  PermissionModeInfo(
    value: 'auto',
    label: 'Auto',
    description: '模型分类器逐次判定，拿不准时才问你',
  ),
  PermissionModeInfo(
    value: 'bypassPermissions',
    label: 'Bypass',
    description: '跳过所有权限检查，手机不再收到确认卡',
    dangerous: true,
  ),
];

PermissionModeInfo permissionModeInfo(String value) {
  for (final info in permissionModeInfos) {
    if (info.value == value) return info;
  }
  return permissionModeInfos.first;
}

String permissionModeLabel(String value) => permissionModeInfo(value).label;
