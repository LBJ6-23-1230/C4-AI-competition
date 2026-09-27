import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CourseInfo, HomeworkDDL } from '../models/AgentModels';

/** 课程与 DDL 按 userId 隔离后的本地快照。 */
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
    const empty: StoredLearningData = { courses: [], homeworkDDLs: [], isDataImported: false };
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

  private static key(userId: string): string {
    return LearningDataStore.KEY_PREFIX + encodeURIComponent(userId.trim());
  }
}
