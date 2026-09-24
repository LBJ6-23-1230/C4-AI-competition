import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProactiveResponse } from '../api/ApiModels';

const DOMAIN: number = 0x5A01;
const TAG: string = 'LearningCard';

export interface LearningCardData {
  /** 卡片内容属于谁。用于身份切换时判断是否需要整体刷新（见 `saveDecision`）。 */
  userId: string;
  title: string;
  taskName: string;
  reason: string;
  durationText: string;
  durationMinutes: number;
  actionText: string;
}

interface RegisteredForm {
  id: string;
  compact: boolean;
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
      // 空串 = 还未被任何身份写过。旧版本存下的数据没有这个字段，
      // 读出来是 undefined，与任何 userId 都不等 → 首次保存会自然覆盖一次，完成迁移。
      userId: '',
      title: '今日学习建议',
      taskName: '打开知学Mate，生成当前任务',
      reason: '根据考试、薄弱点和可用时间，给出下一步行动。',
      durationText: '待生成',
      durationMinutes: 30,
      actionText: '开始专注'
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

  static registerForm(context: common.Context, formId: string, compact: boolean): void {
    if (formId.length === 0) return;
    const registrations: RegisteredForm[] = LearningCardService.readForms(context)
      .filter((item: RegisteredForm) => item.id !== formId);
    registrations.push({ id: formId, compact: compact });
    LearningCardService.writeForms(context, registrations);
  }

  static unregisterForm(context: common.Context, formId: string): void {
    const registrations: RegisteredForm[] = LearningCardService.readForms(context)
      .filter((item: RegisteredForm) => item.id !== formId);
    LearningCardService.writeForms(context, registrations);
  }

  static async saveDecision(context: common.Context, decision: ProactiveResponse): Promise<void> {
    const data: LearningCardData = LearningCardService.fromDecision(decision);
    data.userId = typeof decision.userId === 'string' ? decision.userId : '';
    // ⚠️ 桌面卡片是**全局单份**存储（没有任何身份维度），所以这里必须自己把关，
    // 否则会出现两种难查的现象：
    //   · 换账号后桌面卡片还显示**上一个身份**的任务（无人覆盖它）；
    //   · 后台那次"无事可做"的决策把有效内容擦成空白。
    // 处理原则：身份变了就一定要覆盖（哪怕这次不可执行）；身份没变且不可执行就不动。
    const existing: LearningCardData = LearningCardService.read(context);
    const identityChanged: boolean = existing.userId !== data.userId;
    const actionable: boolean = data.taskName.trim().length > 0 && data.title.trim().length > 0;
    if (!identityChanged && !actionable) {
      return;
    }
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
      userId: '',   // 由 saveDecision 填入决策所属身份
      title: decision.title.length > 0 ? decision.title : '今日学习建议',
      taskName: decision.cardData.taskName ?? decision.body,
      reason: decision.reason.length > 0 ? decision.reason : decision.body,
      durationText: minutes === undefined ? '按计划完成' : `${minutes} 分钟`,
      durationMinutes: minutes === undefined ? 30 : minutes,
      actionText: '开始专注'
    };
  }

  static bindingData(data: LearningCardData, compact: boolean = false): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData({
      cardTitle: data.title,
      taskName: data.taskName,
      reason: data.reason,
      durationText: data.durationText,
      durationMinutes: data.durationMinutes ?? 30,
      actionText: data.actionText,
      isCompact: compact
    });
  }

  static async updateForm(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) return;
    try {
      const registration: RegisteredForm | undefined = LearningCardService.readForms(context)
        .find((item: RegisteredForm) => item.id === formId);
      await formProvider.updateForm(formId, LearningCardService.bindingData(
        LearningCardService.read(context), registration?.compact ?? false));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Update form failed: ${JSON.stringify(error)}`);
    }
  }

  private static async updateRegisteredForms(context: common.Context, data: LearningCardData): Promise<void> {
    const registrations: RegisteredForm[] = LearningCardService.readForms(context);
    for (let index: number = 0; index < registrations.length; index++) {
      try {
        const registration: RegisteredForm = registrations[index];
        await formProvider.updateForm(registration.id,
          LearningCardService.bindingData(data, registration.compact));
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '%{public}s',
          `Update ${registrations[index].id} failed: ${JSON.stringify(error)}`);
      }
    }
  }

  private static readForms(context: common.Context): RegisteredForm[] {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      const raw: string = store.getSync(LearningCardService.KEY_FORM_IDS, '[]') as string;
      const parsed: Object[] = JSON.parse(raw) as Object[];
      const registrations: RegisteredForm[] = [];
      for (let index: number = 0; index < parsed.length; index++) {
        const item: Object = parsed[index];
        if (typeof item === 'string') {
          registrations.push({ id: item as string, compact: false });
        } else {
          registrations.push(item as RegisteredForm);
        }
      }
      return registrations;
    } catch (error) {
      return [];
    }
  }

  private static writeForms(context: common.Context, registrations: RegisteredForm[]): void {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      store.putSync(LearningCardService.KEY_FORM_IDS, JSON.stringify(registrations));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Persist form ids failed: ${JSON.stringify(error)}`);
    }
  }
}
