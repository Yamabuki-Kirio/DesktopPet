import 'system_state.dart';

/// 系统状态 → 建议情绪名。
///
/// 需求「七、系统状态与情绪映射」以 Maya 为例给出了这套建议。
/// 这里只作为**匹配依据**（按情绪名做大小写不敏感匹配），
/// 不绑定任何具体角色，也不写死任何文件名。
///
/// 生成出来的仍然是普通的 `state_mappings` 记录，用户可以随意修改或清空。
const Map<SystemState, List<String>> kSuggestedEmotions = <SystemState, List<String>>{
  SystemState.defaultState: <String>['Cheerful'],
  SystemState.focused: <String>['Thinking', 'Bench_Thinking'],
  SystemState.gaming: <String>['Excited', 'Confident'],
  SystemState.social: <String>['Cheerful', 'Nod'],
  SystemState.entertained: <String>['Excited', 'Surprised'],
  SystemState.tired: <String>['Disheartened', 'Bench_Exasperated'],
  SystemState.away: <String>['Thinking'],
  SystemState.happy: <String>['Cheerful', 'Excited', 'Nod'],
  SystemState.concerned: <String>['Worried'],
  SystemState.error: <String>['Shocked', 'Angry'],

  /// manual 状态刻意留空：必须由用户在状态映射页显式指定图片。
  SystemState.manual: <String>[],
};
