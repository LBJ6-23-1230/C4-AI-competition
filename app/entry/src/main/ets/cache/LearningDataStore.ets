import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CourseInfo, HomeworkDDL } from '../models/AgentModels';

/**
 * 一份账号隔离的课程与 DDL 快照。
 *
 * 课程导入是本地能力，服务端画像只保存由课程派生出的知识点，并不会保存原始课表。
 * 因此这里以 userId 为命名空间落盘，既保证重新登录后可恢复，也避免 A 账号的数据
 * 在切换到 B 账号后继续留在内存中。
 */
export interface StoredLearningData {
  courses: CourseInfo[];
  homeworkDDLs: HomeworkDDL[];
  isDataImported: boolean;
}

export class LearningDataStore {
  private static readonly STORE_NAME: string = 'account_learning_data';
  private static readonly KEY_PREFIX: string = 'learning_data_';
  private static context: common.UIAbilityContext | null = null;

  static initialize(context: common.UIAbilityContext): void {
    LearningDataStore.context = context;
  }

  static load(userId: string): StoredLearningData {
    const empty: StoredLearningData = {
      courses: [],
      homeworkDDLs: [],
      isDataImported: false
    };
    if (LearningDataStore.context === null || userId.trim().length === 0) return empty;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(LearningDataStore.context, {
        name: LearningDataStore.STORE_NAME
      });
      const raw: string = store.getSync(LearningDataStore.key(userId), '') as string;
      if (raw.length === 0) return empty;
      const parsed: StoredLearningData = JSON.parse(raw) as StoredLearningData;
      const courses: CourseInfo[] = Array.isArray(parsed.courses) ? parsed.courses : [];
      const ddls: HomeworkDDL[] = Array.isArray(parsed.homeworkDDLs) ? parsed.homeworkDDLs : [];
      return {
        courses: courses,
        homeworkDDLs: ddls,
        isDataImported: parsed.isDataImported === true
      };
    } catch (error) {
      return empty;
    }
  }

  static save(userId: string, data: StoredLearningData): boolean {
    if (LearningDataStore.context === null || userId.trim().length === 0) return false;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(LearningDataStore.context, {
        name: LearningDataStore.STORE_NAME
      });
      store.putSync(LearningDataStore.key(userId), JSON.stringify(data));
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }

  /** userId 来自服务端，编码后再作为 preferences key，避免特殊字符破坏键名。 */
  private static key(userId: string): string {
    return LearningDataStore.KEY_PREFIX + encodeURIComponent(userId.trim());
  }
}
