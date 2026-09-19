import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProactiveResponse } from '../api/ApiModels';

const DOMAIN: number = 0x5A01;
const TAG: string = 'LearningCard';

export interface LearningCardData {
  title: string;
  taskName: string;
  reason: string;
  durationText: string;
  actionText: string;
}

/**
 * Persists the last useful Agent decision and pushes it to every installed service card.
 * The card extension must not perform network work, so it always renders this local snapshot.
 */
export class LearningCardService {
  private static readonly STORE_NAME: string = 'learning_card';
  private static readonly KEY_DATA: string = 'data';
  private static readonly KEY_FORM_IDS: string = 'form_ids';

  static defaultData(): LearningCardData {
    return {
      title: '今日学习建议',
      taskName: '打开知学搭子，生成当前任务',
      reason: '根据考试、薄弱点和可用时间，给出下一步行动。',
      durationText: '待生成',
      actionText: '打开应用'
    };
  }

  static read(context: common.Context): LearningCardData {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      const raw: string = store.getSync(LearningCardService.KEY_DATA, '') as string;
      if (raw.length === 0) return LearningCardService.defaultData();
      const parsed: LearningCardData = JSON.parse(raw) as LearningCardData;
      return parsed.taskName.length > 0 ? parsed : LearningCardService.defaultData();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Read card snapshot failed: ${JSON.stringify(error)}`);
      return LearningCardService.defaultData();
    }
  }

  static registerForm(context: common.Context, formId: string): void {
    if (formId.length === 0) return;
    const ids: string[] = LearningCardService.readFormIds(context);
    if (ids.indexOf(formId) >= 0) return;
    ids.push(formId);
    LearningCardService.writeFormIds(context, ids);
  }

  static unregisterForm(context: common.Context, formId: string): void {
    const ids: string[] = LearningCardService.readFormIds(context)
      .filter((item: string) => item !== formId);
    LearningCardService.writeFormIds(context, ids);
  }

  static async saveDecision(context: common.Context, decision: ProactiveResponse): Promise<void> {
    const data: LearningCardData = LearningCardService.fromDecision(decision);
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      store.putSync(LearningCardService.KEY_DATA, JSON.stringify(data));
      store.flushSync();
      await LearningCardService.updateRegisteredForms(context, data);
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', `Save card snapshot failed: ${JSON.stringify(error)}`);
    }
  }

  static fromDecision(decision: ProactiveResponse): LearningCardData {
    const minutes: number | undefined = decision.action.preset.durationMinutes ?? decision.cardData.durationMinutes;
    return {
      title: decision.title.length > 0 ? decision.title : '今日学习建议',
      taskName: decision.cardData.taskName ?? decision.body,
      reason: decision.reason.length > 0 ? decision.reason : decision.body,
      durationText: minutes === undefined ? '按计划完成' : `${minutes} 分钟`,
      actionText: '打开应用'
    };
  }

  static bindingData(data: LearningCardData): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData({
      cardTitle: data.title,
      taskName: data.taskName,
      reason: data.reason,
      durationText: data.durationText,
      actionText: data.actionText
    });
  }

  static async updateForm(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) return;
    try {
      await formProvider.updateForm(formId, LearningCardService.bindingData(LearningCardService.read(context)));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Update form failed: ${JSON.stringify(error)}`);
    }
  }

  private static async updateRegisteredForms(context: common.Context, data: LearningCardData): Promise<void> {
    const ids: string[] = LearningCardService.readFormIds(context);
    const binding: formBindingData.FormBindingData = LearningCardService.bindingData(data);
    for (let index: number = 0; index < ids.length; index++) {
      try {
        await formProvider.updateForm(ids[index], binding);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '%{public}s', `Update ${ids[index]} failed: ${JSON.stringify(error)}`);
      }
    }
  }

  private static readFormIds(context: common.Context): string[] {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      const raw: string = store.getSync(LearningCardService.KEY_FORM_IDS, '[]') as string;
      return JSON.parse(raw) as string[];
    } catch (error) {
      return [];
    }
  }

  private static writeFormIds(context: common.Context, ids: string[]): void {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      store.putSync(LearningCardService.KEY_FORM_IDS, JSON.stringify(ids));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Persist form ids failed: ${JSON.stringify(error)}`);
    }
  }
}
