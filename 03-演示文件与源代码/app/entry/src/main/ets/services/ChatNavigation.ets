import router from '@ohos.router';

export class ChatNavigation {
  static chatHome(): string {
    return 'pages/ChatMain';
  }

  static returnToChat(): void {
    // 结束一次 Agent 子流程时清空旧页面，避免反复 push 聊天页把路由栈撑满。
    router.clear();
    router.pushUrl({ url: ChatNavigation.chatHome() });
  }
}
