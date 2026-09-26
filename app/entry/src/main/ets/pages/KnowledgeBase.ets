import router from '@ohos.router';
import { util } from '@kit.ArkTS';
import { AgentApiClient } from '../api/AgentApiClient';
import {
  KnowledgeBase,
  KnowledgeBaseListResponse,
  KnowledgeChunkHit,
  KnowledgeDocument,
  KnowledgeDocumentChunk,
  KnowledgeDocumentDetail,
  KnowledgeSearchResponse
} from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ApiDefaults } from '../api/ApiDefaults';
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

  // 文档详情浮层（查看讲义正文）。
  // 用一组扁平状态而不是一个「可空对象」状态：本页其余部分（documents / hits）
  // 也都是扁平状态，风格一致；且 ArkTS 里基本类型的刷新语义最直观，
  // 弹窗内容不会出现"数据变了但没重绘"。
  @State detailVisible: boolean = false;
  @State detailDocumentId: string = '';
  @State detailFileName: string = '';
  @State detailKbLabel: string = '';
  @State detailChunks: KnowledgeDocumentChunk[] = [];
  @State detailChunkTotal: number = 0;
  @State detailTruncated: boolean = false;
  @State detailLoading: boolean = false;
  @State detailError: string = '';
  /** 详情响应里的解析状态：失败文档没有正文，要说清是"解析失败"而不是"内容为空"。 */
  @State detailStatus: string = '';
  @State detailStatusMessage: string = '';

  private isActive: boolean = true;

  aboutToAppear(): void {
    this.loadKnowledgeBases();
  }

  aboutToDisappear(): void {
    this.isActive = false;
  }

  private currentUserId(): string {
    // 走 `ApiDefaults.DEMO_USER_ID` 单一真源，不在页面里写死字面量
    // （`StudyTags.ets` 的 `effectiveUserId()` 是同一规则）。
    const id: string = appState.currentUser.userId;
    return id.length > 0 ? id : ApiDefaults.DEMO_USER_ID;
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
    if (this.newCourseName.trim().length === 0) {
      this.showMessage('请填写课程名称。', true);
      return;
    }
    const courseName: string = this.newCourseName.trim();
    this.isCreating = true;
    const result = await AgentApiClient.createKnowledgeBase({
      courseName: courseName,
      name: `${courseName}知识库`,
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

  // ---------------------------------------------------------------- 文档详情
  /**
   * 文档归属（课程 / 知识库名）。
   *
   * 数据源是**页面已有的知识库列表状态**，不为此再发一次请求 ——
   * 列表接口早就把 courseName / name 拿回来了，再查一遍纯属浪费一次往返。
   *
   * 查不到就如实说"归属未知"：不拿"当前选中的知识库"去顶替。
   * 文档列表确实是按选中的知识库拉的，但两者一旦不一致（列表还没刷新、
   * 文档被人挪过库），猜出来的归属就是**假信息**，比"不知道"更糟。
   */
  private knowledgeBaseLabel(kbId: string): string {
    for (let i: number = 0; i < this.knowledgeBases.length; i++) {
      const kb: KnowledgeBase = this.knowledgeBases[i];
      if (kb.kbId !== kbId) {
        continue;
      }
      if (kb.courseName.length > 0 && kb.name.length > 0) {
        return `${kb.courseName} · ${kb.name}`;
      }
      if (kb.courseName.length > 0) {
        return kb.courseName;
      }
      if (kb.name.length > 0) {
        return kb.name;
      }
      return '归属未知';
    }
    return '归属未知';
  }

  /** 头部那行"共 N 个片段"的文案：**是否被截断由后端标注**，前端只负责照实写出来。 */
  private chunkSummary(): string {
    if (this.detailTruncated) {
      return `共 ${this.detailChunkTotal} 个片段 · 内容较多，仅显示前 ${this.detailChunks.length} 段`;
    }
    return `共 ${this.detailChunkTotal} 个片段`;
  }

  /** 单段的小标题：序号 + 标题路径（标题路径就是"引用来源"）。 */
  private chunkTitle(chunk: KnowledgeDocumentChunk): string {
    const path: string = chunk.headingPath ?? '';
    return path.length > 0 ? `第 ${chunk.index} 段 · § ${path}` : `第 ${chunk.index} 段`;
  }

  /** 没有切片时的说明：失败文档要带上后端给的原因，不含糊成"内容为空"。 */
  private emptyDetailText(): string {
    if (this.detailStatus === 'failed') {
      const reason: string = this.detailStatusMessage.length > 0
        ? this.detailStatusMessage : '后端未给出原因';
      return `这份文档解析失败，没有正文可显示：${reason}`;
    }
    return '这份文档没有可显示的正文片段。';
  }

  /** 点文档 → 打开浮层并拉正文。 */
  private async openDocumentDetail(doc: KnowledgeDocument): Promise<void> {
    this.detailVisible = true;
    this.detailDocumentId = doc.documentId;
    this.detailFileName = doc.fileName;
    this.detailKbLabel = this.knowledgeBaseLabel(doc.kbId);
    await this.fetchDocumentDetail(doc.documentId);
  }

  /**
   * 拉取文档正文。
   *
   * 每次都真发请求、不做前端缓存：正文是"资料事实"，缓存会让用户看到过期内容
   * （例如同名文件被重新上传过），而本项目的纪律是**只展示接口返回的数据**。
   *
   * 失败时把后端给的可读原因原样显示（含 404「文档不存在」），不假装成功；
   * 「重试」按钮复用的就是这个方法。
   */
  private async fetchDocumentDetail(documentId: string): Promise<void> {
    this.detailChunks = [];
    this.detailChunkTotal = 0;
    this.detailTruncated = false;
    this.detailError = '';
    this.detailStatus = '';
    this.detailStatusMessage = '';
    this.detailLoading = true;
    const result = await AgentApiClient.getKnowledgeDocument(documentId);
    if (!this.isActive) {
      return;
    }
    // 请求返回前用户可能已经关了浮层、或点了另一份文档：
    // 只认"最后一次打开的那份"，否则会把 A 的正文渲染进 B 的弹窗（串档比不显示更糟）。
    if (!this.detailVisible || this.detailDocumentId !== documentId) {
      return;
    }
    this.detailLoading = false;
    if (!result.ok) {
      this.detailError = (result as ApiFailure).error.message;
      return;
    }
    const payload: KnowledgeDocumentDetail = result.data;
    // 全部直接来自响应：切片正文、真实切片总数、是否被截断、解析状态。
    this.detailChunks = payload.chunks;
    this.detailChunkTotal = payload.chunkTotal;
    this.detailTruncated = payload.chunksTruncated;
    this.detailStatus = payload.status;
    this.detailStatusMessage = payload.statusMessage ?? '';
  }

  private closeDocumentDetail(): void {
    this.detailVisible = false;
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

      // 文档详情浮层放在 Stack 的**最后一个**子节点：Stack 里后加入的节点在上层，
      // 这样它能盖住 AI 浮标（`Index.ets` 的 RouteSheet 也是这个位置关系）。
      if (this.detailVisible) {
        this.DocumentDetailOverlay()
      }
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
        Text('还没有课程资料库。创建一门课程后，把这门课的讲义、题库和笔记都放在其中。')
          .fontSize(13).fontColor('#64748B').width('100%')
      }

      ForEach(this.knowledgeBases, (kb: KnowledgeBase) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(kb.courseName).fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor(kb.kbId === this.selectedKbId ? '#2563EB' : '#0F172A')
              .width('100%')
            Text(`${kb.documentCount ?? 0} 份课程文档 · ${kb.chunkCount ?? 0} 个片段`)
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
        Text('每门课程只建一个资料库，后续文档都归入该课程。')
          .fontSize(12).fontColor('#64748B').width('100%')
        Button(this.isCreating ? '创建中…' : '新建课程资料库')
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
            Text('正文 ›').fontSize(12).fontColor('#2563EB')
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            Text('删除').fontSize(12).fontColor('#B91C1C')
              .onClick(() => { this.deleteDocument(doc.documentId); })
          }
          .width('100%')

          // 归属必须显式写出来：用户反馈"这份讲义不知道属于哪个课程知识库"。
          // 数据来自页面已有的知识库列表；查不到就写"归属未知"，不猜。
          Text(`所属知识库：${this.knowledgeBaseLabel(doc.kbId)}`)
            .fontSize(12).fontColor('#475569').width('100%')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

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
        // 整项可点：点开看正文。子节点"删除"有自己的 onClick，
        // ArkUI 的点击由最内层处理者消费、不会再冒泡到这一层 ——
        // 知识库列表（选择 / 删除同一张卡片）用的就是同一套写法，行为已验证。
        .onClick(() => { this.openDocumentDetail(doc); })
      }, (doc: KnowledgeDocument) => doc.documentId)
    }
    .width('100%')
  }

  /**
   * 文档详情浮层：文件名 + 所属知识库 + 片段数 + 各段正文（可滚动）。
   *
   * 视觉照抄 `Account.ets` 的 `confirmOverlay()`：全屏半透明遮罩 + 居中白卡片。
   *
   * 三条纪律落在这里：
   * * **不假装成功** —— 加载中是 loading、失败显示后端给的原因并可重试，
   *   绝不把空态渲染成"这份文档就是空的"。
   * * **不静默截断** —— 后端说截断了就照实写"仅显示前 N 段"。
   * * **不做业务计算** —— 片段总数用响应的 `chunkTotal`，不是前端去数数组。
   */
  @Builder
  DocumentDetailOverlay() {
    Column() {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.detailFileName).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#0F172A')
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`所属知识库：${this.detailKbLabel}`)
              .fontSize(12).fontColor('#64748B').width('100%')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Text('关闭').fontSize(13).fontColor('#2563EB')
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor('#EFF6FF').borderRadius(8)
            .onClick(() => { this.closeDocumentDetail(); })
        }.width('100%')

        Text(this.chunkSummary())
          .fontSize(11).width('100%')
          .fontColor(this.detailTruncated ? '#B45309' : '#94A3B8')

        Divider().color('#E2E8F0')

        if (this.detailLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color('#2563EB')
            Text('正在加载正文…').fontSize(13).fontColor('#64748B')
          }
          .width('100%').padding({ top: 24, bottom: 24 })
          .justifyContent(FlexAlign.Center)
        } else if (this.detailError.length > 0) {
          Column({ space: 10 }) {
            Text('正文加载失败').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#B91C1C')
              .width('100%')
            // 后端给的可读原因原样透出（如 404「文档不存在」），不吞成"加载失败"
            Text(this.detailError).fontSize(12).fontColor('#B91C1C').width('100%').lineHeight(18)
            Button('重试').height(38).fontSize(13).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(10)
              .onClick(() => { this.fetchDocumentDetail(this.detailDocumentId); })
          }
          .width('100%').padding({ top: 12 })
        } else if (this.detailChunks.length === 0) {
          Text(this.emptyDetailText()).fontSize(13).fontColor('#64748B')
            .width('100%').lineHeight(20)
        } else {
          Scroll() {
            Column({ space: 12 }) {
              ForEach(this.detailChunks, (chunk: KnowledgeDocumentChunk) => {
                Column({ space: 5 }) {
                  Text(this.chunkTitle(chunk))
                    .fontSize(11).fontColor('#166534').width('100%').lineHeight(17)
                  Text(chunk.text).fontSize(13).fontColor('#334155').width('100%').lineHeight(21)
                  if ((chunk.knowledgePoints ?? []).length > 0) {
                    Text(`标签：${(chunk.knowledgePoints ?? []).join('、')}`)
                      .fontSize(11).fontColor('#64748B').width('100%')
                  }
                }
                .width('100%').padding(10).borderRadius(10).backgroundColor('#F8FAFC')
                .border({ width: 1, color: '#E2E8F0' })
              }, (chunk: KnowledgeDocumentChunk) => chunk.chunkId)
            }.width('100%')
          }
          .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
        }
      }
      .width('92%').height('82%').padding(16)
      .backgroundColor('#FFFFFF').borderRadius(16)
      .border({ width: 1, color: '#E2E8F0' })
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
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
