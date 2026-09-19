import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { LearningCardService } from '../services/LearningCardService';

export default class LearningCardFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = this.getFormId(want);
    LearningCardService.registerForm(this.context, formId);
    return LearningCardService.bindingData(LearningCardService.read(this.context));
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
}
