import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { LearningCardService } from '../services/LearningCardService';

export default class LearningCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = this.getFormId(want);
    const compact: boolean = this.isCompact(want);
    LearningCardService.registerForm(this.context, formId, compact);
    return LearningCardService.bindingData(LearningCardService.read(this.context), compact);
  }

  onUpdateForm(formId: string): void {
    void LearningCardService.updateForm(this.context, formId);
  }

  onRemoveForm(formId: string): void {
    LearningCardService.unregisterForm(this.context, formId);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  private getFormId(want: Want): string {
    if (want.parameters === undefined) return '';
    const value: Object | undefined = want.parameters[formInfo.FormParam.IDENTITY_KEY];
    return value === undefined ? '' : `${value}`;
  }

  private isCompact(want: Want): boolean {
    if (want.parameters === undefined) return true;
    const value: Object | undefined = want.parameters[formInfo.FormParam.DIMENSION_KEY];
    return value === undefined || Number(value) === formInfo.FormDimension.Dimension_2_2;
  }
}
