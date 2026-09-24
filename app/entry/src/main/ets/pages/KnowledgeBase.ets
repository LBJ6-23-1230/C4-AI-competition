import router from '@ohos.router';
import { util } from '@kit.ArkTS';
import { AgentApiClient } from '../api/AgentApiClient';
import {
  KnowledgeBase,
  KnowledgeBaseListResponse,
  KnowledgeChunkHit,
  KnowledgeDocument,
  KnowledgeSearchResponse
} from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { AIFloatButton } from '../components/AIFloatButton';
import { appState } from '../data/AppState';

/**
 * 我的知识库（知识库第一期）
 *
 * 对应设计文档 `docs/12-知识库设计方案.md` 的三件事，收在一个页面里：
 *   1. 课程知识库列表（新建 / 选择 / 删除）
 *   2. 文件上传 + 文件与知识点管理（**处理状态真实展示，含失败原因**）
 *   3. 检索测试（命中片段 + 标题路径，即"引用来源"的雏形）
 *
 * 两个刻意的设计：
 * * **失败态必须可见**。PDF 第一期不支持、编码错误都会返回 `status=failed` +
 *   可读原因。界面上照实显示 —— 评委看到"能失败、能重试"比看到永远成功更可信。
 * * **不做假数据**。所有数字（切片数、知识点、命中分数）都来自后端响应，
 *   前端不编造"AI 从资料中学到了什么"。
 */
@Entry
@Component
struct KnowledgeBasePage {
  @State isLoading: boolean = true;
  @State message: string = '';
  @State messageIsError: boolean = false;

  @State knowledgeBases: KnowledgeBase[] = [];
  @State selectedKbId: string = '';
  @State documents: KnowledgeDocument[] = [];
  @State activeTab: string = 'documents';   // documents | upload | knowledge | search

  // 新建知识库表单
  @State newCourseName: string = '';
  @State newName: string = '';
  @State isCreating: boolean = false;

  // 上传
  @State isUploading: boolean = false;
  @State sampleText: string = '';
  @State sampleFileName: string = '';

  // 检索
  @State searchQuery: string = '';
  @State isSearching: boolean = false;
  @State hits: KnowledgeChunkHit[] = [];
  @State retrievalMode: string = '';
  @State lastScanned: number = 0;

  private isActive: boolean = true;

  aboutToAppear(): void {
    this.loadKnowledgeBases();
  }

  aboutToDisappear(): void {
    this.isActive = false;
  }

  private currentUserId(): string {
    const id: string = appState.currentUser.userId;
    return id.length > 0 ? id : 'demo-user';
  }

  private showMessage(text: string, isError: boolean): void {
    this.message = text;
    this.messageIsError = isError;
  }

  // ---------------------------------------------------------------- 数据加载
  private async loadKnowledgeBases(): Promise<void> {
    this.isLoading = true;
    const result = await AgentApiClient.listKnowledgeBases(this.currentUserId());
    if (!this.isActive) {
      return;
    }
    this.isLoading = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const payload: KnowledgeBaseListResponse = result.data;
    this.knowledgeBases = payload.knowledgeBases;
    if (this.selectedKbId.length === 0 && this.knowledgeBases.length > 0) {
      this.selectedKbId = this.knowledgeBases[0].kbId;
    }
    if (this.selectedKbId.length > 0) {
      await this.loadDocuments();
    }
  }

  private async loadDocuments(): Promise<void> {
    if (this.selectedKbId.length === 0) {
      this.documents = [];
      return;
    }
    const result = await AgentApiClient.getKnowledgeBase(this.selectedKbId);
    if (!this.isActive) {
      return;
    }
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    this.documents = result.data.documents ?? [];
  }

  private async createKnowledgeBase(): Promise<void> {
    if (this.isCreating) {
      return;
    }
    if (this.newCourseName.trim().length === 0 || this.newName.trim().length === 0) {
      this.showMessage('请填写课程名与知识库名称。', true);
      return;
    }
    this.isCreating = true;
    const result = await AgentApiClient.createKnowledgeBase({
      courseName: this.newCourseName.trim(),
      name: this.newName.trim(),
      userId: this.currentUserId()
    });
    if (!this.isActive) {
      return;
    }
    this.isCreating = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    this.selectedKbId = result.data.kbId;
    this.newCourseName = '';
    this.newName = '';
    this.showMessage(`已创建知识库「${result.data.name}」。`, false);
    await this.loadKnowledgeBases();
  }

  private async deleteKnowledgeBase(kbId: string): Promise<void> {
    const result = await AgentApiClient.deleteKnowledgeBase(kbId);
    if (!this.isActive) {
      return;
    }
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    if (this.selectedKbId === kbId) {
      this.selectedKbId = '';
      this.documents = [];
      this.hits = [];
    }
    this.showMessage('知识库已删除。', false);
    await this.loadKnowledgeBases();
  }

  // ---------------------------------------------------------------- 上传
  /**
   * 把文本编码为 base64。
   *
   * 用 `@kit.ArkTS` 的 `util`（**静态 import**，不能用 `require`：
   * ArkTS 不支持 CommonJS 动态引入，编译期就会报错）。
   * 编码失败返回空串，由调用方给出可读提示，不抛异常。
   */
  private encodeBase64(text: string): string {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(text);
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (error) {
      return '';
    }
  }

  private async upload(fileName: string, content: string): Promise<void> {
    if (this.selectedKbId.length === 0) {
      this.showMessage('请先选择或创建一个知识库。', true);
      return;
    }
    if (this.isUploading) {
      return;
    }
    const encoded: string = this.encodeBase64(content);
    if (encoded.length === 0) {
      this.showMessage('内容编码失败，请重试。', true);
      return;
    }
    this.isUploading = true;
    const result = await AgentApiClient.uploadKnowledgeDocument(this.selectedKbId, {
      fileName: fileName,
      contentBase64: encoded,
      mimeType: 'text/plain',
      sizeBytes: content.length,
      userId: this.currentUserId()
    });
    if (!this.isActive) {
      return;
    }
    this.isUploading = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const doc: KnowledgeDocument = result.data;
    if (doc.status === 'failed') {
      // 失败态照实展示 —— 不假装成功
      this.showMessage(`「${doc.fileName}」解析失败：${doc.statusMessage ?? '未知原因'}`, true);
    } else {
      this.showMessage(
        `「${doc.fileName}」已解析：${doc.chunkCount ?? 0} 个片段、` +
        `${(doc.knowledgePoints ?? []).length} 个知识点。`, false);
    }
    await this.loadKnowledgeBases();
    this.activeTab = 'documents';
  }

  private async uploadSample(): Promise<void> {
    const sample: string =
      '# 第3章 树与二叉树\n\n' +
      '## 3.2 二叉树遍历\n\n' +
      '前序遍历的顺序是根-左-右。中序遍历的顺序是左-根-右。\n\n' +
      '## 3.2.3 后序遍历\n\n' +
      '后序遍历的顺序是左-右-根，因此根节点总是最后被访问。\n' +
      '常见错误：把后序遍历与中序遍历的访问时机混淆。\n\n' +
      '## 3.3 递归理解\n\n' +
      '递归理解的核心是终止条件与调用栈。递归理解不到位会导致遍历写错。\n' +
      '递归理解的练习建议从简单树开始。\n';
    await this.upload('二叉树复习讲义.md', sample);
  }

  private async deleteDocument(documentId: string): Promise<void> {
    const result = await AgentApiClient.deleteKnowledgeDocument(documentId);
    if (!this.isActive) {
      return;
    }
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    this.showMessage('文档已删除。', false);
    await this.loadKnowledgeBases();
  }

  // ---------------------------------------------------------------- 检索
  private async runSearch(): Promise<void> {
    if (this.selectedKbId.length === 0) {
      this.showMessage('请先选择知识库。', true);
      return;
    }
    if (this.searchQuery.trim().length === 0) {
      this.showMessage('请输入检索内容。', true);
      return;
    }
    if (this.isSearching) {
      return;
    }
    this.isSearching = true;
    const result = await AgentApiClient.searchKnowledgeBase(this.selectedKbId, {
      query: this.searchQuery.trim(),
      topK: 5
    });
    if (!this.isActive) {
      return;
    }
    this.isSearching = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const payload: KnowledgeSearchResponse = result.data;
    this.hits = payload.hits;
    this.retrievalMode = payload.retrievalMode;
    this.lastScanned = payload.totalScanned;
    this.showMessage(this.hits.length > 0
      ? `命中 ${this.hits.length} 个片段（扫描 ${this.lastScanned} 个）。`
      : '没有命中。换个说法试试，或先上传更相关的资料。', this.hits.length === 0);
  }

  /** 收集当前知识库的全部知识点（去重）。 */
  private allKnowledgePoints(): string[] {
    const points: string[] = [];
    for (let i: number = 0; i < this.documents.length; i++) {
      const list: string[] = this.documents[i].knowledgePoints ?? [];
      for (let j: number = 0; j < list.length; j++) {
        if (points.indexOf(list[j]) < 0) {
          points.push(list[j]);
        }
      }
    }
    return points;
  }

  private selectedKb(): KnowledgeBase | null {
    for (let i: number = 0; i < this.knowledgeBases.length; i++) {
      if (this.knowledgeBases[i].kbId === this.selectedKbId) {
        return this.knowledgeBases[i];
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- 界面
  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.TopBar()
        Scroll() {
          Column({ space: 14 }) {
            this.MessageBanner()
            this.KnowledgeBaseSection()
            if (this.selectedKbId.length > 0) {
              this.TabBar()
              if (this.activeTab === 'documents') {
                this.DocumentsSection()
              } else if (this.activeTab === 'upload') {
                this.UploadSection()
              } else if (this.activeTab === 'knowledge') {
                this.KnowledgeSection()
              } else {
                this.SearchSection()
              }
            }
            Blank().height(80)
          }
          .width('100%').padding({ left: 16, right: 16, bottom: 20 })
        }
        .layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('100%').backgroundColor('#F8FAFC')

      AIFloatButton()
    }
    .width('100%').height('100%')
  }

  @Builder
  TopBar() {
    Row({ space: 12 }) {
      Text('←').fontSize(20).fontColor('#0F172A')
        .onClick(() => router.back())
      Column({ space: 2 }) {
        Text('我的知识库').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        Text('上传课程资料，让 Agent 有据可依')
          .fontSize(12).fontColor('#64748B')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.isLoading) {
        LoadingProgress().width(20).height(20).color('#2563EB')
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 12 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  MessageBanner() {
    if (this.message.length > 0) {
      Text(this.message)
        .fontSize(13).lineHeight(20).width('100%').padding(12).borderRadius(10)
        .fontColor(this.messageIsError ? '#B91C1C' : '#166534')
        .backgroundColor(this.messageIsError ? '#FEF2F2' : '#F0FDF4')
    }
  }

  @Builder
  KnowledgeBaseSection() {
    Column({ space: 10 }) {
      Text('课程知识库').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        .width('100%')

      if (this.knowledgeBases.length === 0 && !this.isLoading) {
        Text('还没有知识库。按课程建一个，例如「数据结构期末复习库」。')
          .fontSize(13).fontColor('#64748B').width('100%')
      }

      ForEach(this.knowledgeBases, (kb: KnowledgeBase) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(kb.name).fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor(kb.kbId === this.selectedKbId ? '#2563EB' : '#0F172A')
              .width('100%')
            Text(`${kb.courseName} · ${kb.documentCount ?? 0} 份文档 · ${kb.chunkCount ?? 0} 个片段`)
              .fontSize(12).fontColor('#64748B').width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Text('删除').fontSize(12).fontColor('#B91C1C')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => { this.deleteKnowledgeBase(kb.kbId); })
        }
        .width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
        .border({ width: 1, color: kb.kbId === this.selectedKbId ? '#2563EB' : '#E2E8F0' })
        .onClick(() => {
          this.selectedKbId = kb.kbId;
          this.hits = [];
          this.loadDocuments();
        })
      }, (kb: KnowledgeBase) => kb.kbId)

      // 新建
      Column({ space: 8 }) {
        TextInput({ placeholder: '课程名，如「数据结构」', text: this.newCourseName })
          .height(44).fontSize(14).onChange((value: string) => { this.newCourseName = value; })
        TextInput({ placeholder: '知识库名称，如「数据结构期末复习库」', text: this.newName })
          .height(44).fontSize(14).onChange((value: string) => { this.newName = value; })
        Button(this.isCreating ? '创建中…' : '新建知识库')
          .width('100%').height(44).fontSize(14).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(10)
          .enabled(!this.isCreating)
          .onClick(() => { this.createKnowledgeBase(); })
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor('#FFFFFF').border({ width: 1, color: '#E2E8F0' })
    }
    .width('100%')
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      this.TabChip('documents', '文件')
      this.TabChip('upload', '上传')
      this.TabChip('knowledge', '知识点')
      this.TabChip('search', '检索测试')
    }
    .width('100%')
  }

  @Builder
  TabChip(key: string, label: string) {
    Text(label)
      .fontSize(13).fontWeight(this.activeTab === key ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.activeTab === key ? '#FFFFFF' : '#475569')
      .backgroundColor(this.activeTab === key ? '#2563EB' : '#FFFFFF')
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(16)
      .border({ width: 1, color: this.activeTab === key ? '#2563EB' : '#E2E8F0' })
      .onClick(() => { this.activeTab = key; })
  }

  @Builder
  DocumentsSection() {
    Column({ space: 10 }) {
      if (this.documents.length === 0) {
        Text('这个知识库还没有文件。切到「上传」添加讲义、题库或笔记。')
          .fontSize(13).fontColor('#64748B').width('100%')
          .padding(12).backgroundColor('#FFFFFF').borderRadius(12)
      }
      ForEach(this.documents, (doc: KnowledgeDocument) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(doc.fileName).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            // 状态标签：失败必须显眼
            Text(doc.status === 'ready' ? '已解析' : '解析失败')
              .fontSize(11).fontColor('#FFFFFF')
              .backgroundColor(doc.status === 'ready' ? '#10B981' : '#DC2626')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(8)
            Text('删除').fontSize(12).fontColor('#B91C1C')
              .onClick(() => { this.deleteDocument(doc.documentId); })
          }
          .width('100%')

          if (doc.status === 'ready') {
            Text(`${doc.charCount ?? 0} 字 · ${doc.chunkCount ?? 0} 个片段`)
              .fontSize(12).fontColor('#64748B').width('100%')
          } else {
            // 失败原因照实展示，不吞掉
            Text(doc.statusMessage ?? '未知原因')
              .fontSize(12).fontColor('#B91C1C').width('100%').lineHeight(18)
          }

          if ((doc.knowledgePoints ?? []).length > 0) {
            Text(`知识点：${(doc.knowledgePoints ?? []).join('、')}`)
              .fontSize(12).fontColor('#2563EB').width('100%').lineHeight(18)
            Text(`AI 从你的资料中学到：识别 ${(doc.knowledgePoints ?? []).length} 个知识点、` +
              `提取 ${doc.chunkCount ?? 0} 个可用于出题的片段` +
              ((doc.errorPointCandidates ?? []).length > 0
                ? `、发现 ${(doc.errorPointCandidates ?? []).length} 个易错点` : ''))
              .fontSize(12).fontColor('#166534').width('100%').lineHeight(18)
          }
        }
        .width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
        .border({ width: 1, color: doc.status === 'ready' ? '#E2E8F0' : '#FECACA' })
      }, (doc: KnowledgeDocument) => doc.documentId)
    }
    .width('100%')
  }

  @Builder
  UploadSection() {
    Column({ space: 12 }) {
      Text('支持 TXT / Markdown / CSV / JSON。PDF 暂不支持（会明确提示失败原因）。')
        .fontSize(12).fontColor('#64748B').width('100%').lineHeight(18)

      TextArea({ placeholder: '把讲义 / 笔记内容粘贴到这里…', text: this.sampleText })
        .height(160).fontSize(13)
        .onChange((value: string) => { this.sampleText = value; })

      TextInput({ placeholder: '文件名，如「二叉树复习讲义.md」', text: this.sampleFileName })
        .height(44).fontSize(14)
        .onChange((value: string) => { this.sampleFileName = value; })

      Button(this.isUploading ? '上传中…' : '上传并解析')
        .width('100%').height(46).fontSize(15).fontColor('#FFFFFF')
        .backgroundColor('#2563EB').borderRadius(10)
        .enabled(!this.isUploading)
        .onClick(() => {
          const name: string = this.sampleFileName.trim().length > 0
            ? this.sampleFileName.trim() : '我的讲义.md';
          this.upload(name, this.sampleText);
        })

      Button('使用示例讲义快速体验')
        .width('100%').height(44).fontSize(14).fontColor('#2563EB')
        .backgroundColor('#FFFFFF').borderRadius(10)
        .border({ width: 1, color: '#BFDBFE' })
        .enabled(!this.isUploading)
        .onClick(() => { this.uploadSample(); })
    }
    .width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  KnowledgeSection() {
    Column({ space: 10 }) {
      Text('从你的资料中识别出的知识点').fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor('#0F172A').width('100%')

      if (this.allKnowledgePoints().length === 0) {
        Text('还没有识别到知识点。上传含标题层级的讲义效果最好。')
          .fontSize(13).fontColor('#64748B').width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.allKnowledgePoints(), (point: string) => {
            Text(point)
              .fontSize(12).fontColor('#2563EB')
              .backgroundColor('#EFF6FF')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(14)
              .margin({ right: 8, bottom: 8 })
          }, (point: string) => point)
        }.width('100%')
      }

      // 易错点：来自确定性规则（命中"注意/常见错误/易错"等语境的句子）
      if (this.gatherErrorPoints().length > 0) {
        Divider().color('#E2E8F0').margin({ top: 6, bottom: 6 })
        Text('常见易错点').fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor('#0F172A').width('100%')
        ForEach(this.gatherErrorPoints(), (item: string) => {
          Text(`· ${item}`).fontSize(12).fontColor('#B45309')
            .width('100%').lineHeight(18)
        }, (item: string) => item)
      }
    }
    .width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E2E8F0' })
  }

  private gatherErrorPoints(): string[] {
    const items: string[] = [];
    for (let i: number = 0; i < this.documents.length; i++) {
      const list: string[] = this.documents[i].errorPointCandidates ?? [];
      for (let j: number = 0; j < list.length; j++) {
        if (items.indexOf(list[j]) < 0) {
          items.push(list[j]);
        }
      }
    }
    return items;
  }

  @Builder
  SearchSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '例如：后序遍历的顺序', text: this.searchQuery })
          .layoutWeight(1).height(44).fontSize(14)
          .onChange((value: string) => { this.searchQuery = value; })
          .onSubmit(() => { this.runSearch(); })
        Button(this.isSearching ? '检索中' : '检索')
          .height(44).fontSize(14).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(10)
          .enabled(!this.isSearching)
          .onClick(() => { this.runSearch(); })
      }.width('100%')

      if (this.retrievalMode.length > 0) {
        Text(`检索方式：${this.retrievalMode} · 扫描 ${this.lastScanned} 个片段`)
          .fontSize(11).fontColor('#94A3B8').width('100%')
      }

      ForEach(this.hits, (hit: KnowledgeChunkHit) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(hit.fileName ?? '未知文件').fontSize(12).fontWeight(FontWeight.Bold)
              .fontColor('#2563EB').layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(hit.score.toFixed(2)).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor('#2563EB')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8)
          }.width('100%')

          // 标题路径就是"引用来源"，这是知识库最核心的价值展示
          if ((hit.headingPath ?? '').length > 0) {
            Text(`§ ${hit.headingPath}`)
              .fontSize(12).fontColor('#166534').width('100%').lineHeight(18)
          }
          Text(hit.text).fontSize(13).fontColor('#334155')
            .width('100%').lineHeight(20).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if ((hit.knowledgePoints ?? []).length > 0) {
            Text(`标签：${(hit.knowledgePoints ?? []).join('、')}`)
              .fontSize(11).fontColor('#64748B').width('100%')
          }
        }
        .width('100%').padding(12).borderRadius(12).backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#E2E8F0' })
      }, (hit: KnowledgeChunkHit) => hit.chunkId)
    }
    .width('100%')
  }
}
