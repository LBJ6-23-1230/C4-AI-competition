import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** Persists the minimal state required to resume the fixed offline demo. */
export class FixtureDemoStateStore {
  private static readonly STORE_NAME: string = 'fixture_demo_state';
  private static readonly KEY_EXERCISE_SUBMITTED: string = 'exercise_submitted';
  private static readonly KEY_MASTERY_SCORE: string = 'mastery_score';
  private static readonly KEY_ASSESSMENT_SCORE: string = 'assessment_score';
  /** 与后端演示基线一致：初始掌握度 42。 */
  private static readonly INITIAL_MASTERY_SCORE: number = 42;
  private static context: common.UIAbilityContext | null = null;
  private static exerciseSubmitted: boolean = false;
  private static masteryScore: number = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;
  private static assessmentScore: number = 66.67;

  static initialize(context: common.UIAbilityContext): boolean {
    FixtureDemoStateStore.context = context;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      FixtureDemoStateStore.exerciseSubmitted =
        store.getSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED, false) as boolean;
      FixtureDemoStateStore.masteryScore =
        store.getSync(FixtureDemoStateStore.KEY_MASTERY_SCORE,
          FixtureDemoStateStore.INITIAL_MASTERY_SCORE) as number;
      FixtureDemoStateStore.assessmentScore =
        store.getSync(FixtureDemoStateStore.KEY_ASSESSMENT_SCORE, 66.67) as number;
      return true;
    } catch (error) {
      FixtureDemoStateStore.exerciseSubmitted = false;
      FixtureDemoStateStore.masteryScore = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;
      FixtureDemoStateStore.assessmentScore = 66.67;
      return false;
    }
  }

  static isExerciseSubmitted(): boolean {
    return FixtureDemoStateStore.exerciseSubmitted;
  }

  /** 离线 Fixture 的掌握度由本模块持有，保证"改答案 → 分数变 → 掌握度变"在离线模式同样成立。 */
  static getMasteryScore(): number {
    return FixtureDemoStateStore.masteryScore;
  }

  static getAssessmentScore(): number {
    return FixtureDemoStateStore.assessmentScore;
  }

  static setMasteryScore(value: number): boolean {
    FixtureDemoStateStore.masteryScore = Math.max(0, Math.min(100, value));
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static setAssessmentResult(masteryScore: number, assessmentScore: number): boolean {
    FixtureDemoStateStore.masteryScore = Math.max(0, Math.min(100, masteryScore));
    FixtureDemoStateStore.assessmentScore = Math.max(0, Math.min(100, assessmentScore));
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static markExerciseSubmitted(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static reset(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = false;
    FixtureDemoStateStore.masteryScore = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;
    FixtureDemoStateStore.assessmentScore = 66.67;
    return FixtureDemoStateStore.persist();
  }

  private static persist(): boolean {
    if (FixtureDemoStateStore.context === null) {
      return true;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(FixtureDemoStateStore.context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      store.putSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED,
        FixtureDemoStateStore.exerciseSubmitted);
      store.putSync(FixtureDemoStateStore.KEY_MASTERY_SCORE,
        FixtureDemoStateStore.masteryScore);
      store.putSync(FixtureDemoStateStore.KEY_ASSESSMENT_SCORE,
        FixtureDemoStateStore.assessmentScore);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
