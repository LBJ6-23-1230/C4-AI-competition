import { CourseInfo, HomeworkDDL } from '../models/AgentModels';

/**
 * Model3DRenderer — 三维立体点线模型渲染器
 *
 * 将用户的薄弱点、DDL、课程信息可视化为可交互的3D点线模型。
 * 每个顶点代表一个学习要素，连线代表它们之间的关联关系。
 *
 * 使用透视投影 + Y轴旋转实现立体效果，支持触摸拖拽旋转。
 */

/** 3D空间中的节点 */
export interface ModelNode {
  id: string;
  label: string;
  subLabel: string;
  x: number;
  y: number;
  z: number;
  radius: number;
  color: string;
  glowColor: string;
  category: 'user' | 'weakness' | 'ddl' | 'course';
  priority: number; // 0-100, 控制节点大小
}

/** 连接两个节点的边 */
export interface ModelEdge {
  fromId: string;
  toId: string;
  color: string;
  width: number;
  dashPattern: number[];
}

/** 2D投影后的节点（用于点击检测和渲染） */
export interface ProjectedNode {
  id: string;
  label: string;
  subLabel: string;
  sx: number;
  sy: number;
  radius: number;
  color: string;
  glowColor: string;
  depth: number; // z-depth 用于控制透明度/大小
  category: string;
}

/** 2D投影后的边 */
export interface ProjectedEdge {
  fromX: number;
  fromY: number;
  toX: number;
  toY: number;
  color: string;
  width: number;
  opacity: number;
  dashPattern: number[];
}

/** 投影结果 */
export interface ProjectionResult {
  nodes: ProjectedNode[];
  edges: ProjectedEdge[];
}

export class Model3DRenderer {
  private nodes: ModelNode[] = [];
  private edges: ModelEdge[] = [];
  private rotationY: number = 0.5;       // Y轴旋转角度（弧度）
  private rotationX: number = -0.3;      // X轴轻微倾斜角度
  private autoRotateSpeed: number = 0.003; // 自动旋转速度
  private fov: number = 500;             // 视场角
  private centerX: number = 0;
  private centerY: number = 0;
  private width: number = 0;
  private height: number = 0;

  // 缩放
  private zoomLevel: number = 1.0;       // 缩放级别 (0.5 ~ 2.5)
  private minZoom: number = 0.5;
  private maxZoom: number = 2.5;

  // 触摸交互 — 单指旋转
  private isDragging: boolean = false;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private targetRotationY: number = 0.5;
  private targetRotationX: number = -0.3;

  // 触摸交互 — 双指缩放
  private isPinching: boolean = false;
  private lastPinchDistance: number = 0;

  constructor() {
  }

  /**
   * 根据用户数据构建3D模型节点和边
   */
  buildModel(
    weaknesses: string[],
    strengths: string[],
    ddls: HomeworkDDL[],
    courses: CourseInfo[]
  ): void {
    this.nodes = [];
    this.edges = [];

    // ===== 中心节点：用户 =====
    this.nodes.push({
      id: 'center',
      label: '我',
      subLabel: '学习者',
      x: 0, y: 0, z: 0,
      radius: 22,
      color: '#2F7D6D',
      glowColor: 'rgba(47,125,109,0.4)',
      category: 'user',
      priority: 100
    });

    // ===== 薄弱点节点（内圈） =====
    const weaknessRadius: number = 1.8;
    const weaknessCount: number = weaknesses.length + 1; // +1 for "综合能力"
    const weaknessColor: string = '#E04F5F';
    const weaknessGlow: string = 'rgba(224,79,95,0.35)';

    for (let i: number = 0; i < weaknesses.length; i++) {
      const angle: number = (Math.PI * 2 * i) / weaknessCount;
      const px: number = Math.cos(angle) * weaknessRadius;
      const py: number = (i % 3 - 1) * 1.0; // 轻微的高度变化
      const pz: number = Math.sin(angle) * weaknessRadius;

      // 找到相关的课程
      let relatedCourse: string = '';
      for (let j: number = 0; j < courses.length; j++) {
        const c: CourseInfo = courses[j];
        if ((c.courseName === '数据结构' &&
          (weaknesses[i].indexOf('树') !== -1 || weaknesses[i].indexOf('图') !== -1 ||
            weaknesses[i].indexOf('遍历') !== -1 || weaknesses[i].indexOf('递归') !== -1)) ||
          (c.courseName === '操作系统' &&
            (weaknesses[i].indexOf('调度') !== -1 || weaknesses[i].indexOf('进程') !== -1))) {
          relatedCourse = c.courseName;
          break;
        }
      }

      // 从DDL数据计算紧急度
      const relatedDDLs: HomeworkDDL[] = ddls.filter((d: HomeworkDDL) => {
        return (relatedCourse.length > 0 && d.courseName === relatedCourse) ||
          (weaknesses[i].indexOf('树') !== -1 && d.title.indexOf('树') !== -1) ||
          (weaknesses[i].indexOf('调度') !== -1 && d.title.indexOf('调度') !== -1);
      });

      let urgencyBoost: number = 0;
      if (relatedDDLs.length > 0) {
        for (let d: number = 0; d < relatedDDLs.length; d++) {
          const boost: number = Math.max(0, 1 - relatedDDLs[d].daysLeft / 14);
          if (boost > urgencyBoost) {
            urgencyBoost = boost;
          }
        }
      }

      this.nodes.push({
        id: `weakness-${i}`,
        label: weaknesses[i],
        subLabel: relatedCourse.length > 0 ? `${relatedCourse}薄弱点` : '通用薄弱点',
        x: px, y: py, z: pz,
        radius: 10 + urgencyBoost * 6,
        color: weaknessColor,
        glowColor: weaknessGlow,
        category: 'weakness',
        priority: 50 + Math.round(urgencyBoost * 30)
      });

      // 中心 → 薄弱点连线
      this.edges.push({
        fromId: 'center',
        toId: `weakness-${i}`,
        color: '#E04F5F',
        width: 1.5,
        dashPattern: [6, 4]
      });
    }

    // ===== DDL节点（中圈） =====
    const ddlRadius: number = 2.8;
    const urgentDDLs: HomeworkDDL[] = [...ddls]
      .sort((a: HomeworkDDL, b: HomeworkDDL) => a.daysLeft - b.daysLeft)
      .slice(0, 5);

    for (let i: number = 0; i < urgentDDLs.length; i++) {
      const ddl: HomeworkDDL = urgentDDLs[i];
      const angle: number = (Math.PI * 2 * i) / urgentDDLs.length + 0.3;
      const px: number = Math.cos(angle) * ddlRadius;
      const py: number = (i % 2 === 0 ? 0.5 : -0.5) * 1.2;
      const pz: number = Math.sin(angle) * ddlRadius;

      const isUrgent: boolean = ddl.daysLeft <= 3;
      const ddlColor: string = isUrgent ? '#FF4757' : (ddl.daysLeft <= 7 ? '#FF6B81' : '#FFA502');

      this.nodes.push({
        id: `ddl-${ddl.id}`,
        label: ddl.title.length > 8 ? ddl.title.substring(0, 8) + '...' : ddl.title,
        subLabel: `${ddl.courseName} · ${ddl.daysLeft}天后截止`,
        x: px, y: py, z: pz,
        radius: isUrgent ? 14 : 10,
        color: ddlColor,
        glowColor: isUrgent ? 'rgba(255,71,87,0.4)' : 'rgba(255,165,2,0.3)',
        category: 'ddl',
        priority: Math.round(100 - ddl.daysLeft * 5)
      });

      // 连接DDL到相关的薄弱点
      for (let w: number = 0; w < weaknesses.length; w++) {
        const weakNodeId: string = `weakness-${w}`;
        const weakNode: ModelNode | undefined = this.nodes.find((n: ModelNode) => n.id === weakNodeId);
        if (weakNode !== undefined && weakNode.subLabel.indexOf(ddl.courseName) !== -1) {
          this.edges.push({
            fromId: weakNodeId,
            toId: `ddl-${ddl.id}`,
            color: '#FFA502',
            width: 1.0,
            dashPattern: [4, 6]
          });
        }
      }

      // 连接DDL到中心
      if (isUrgent || i < 2) {
        this.edges.push({
          fromId: 'center',
          toId: `ddl-${ddl.id}`,
          color: '#FF6B81',
          width: 1.2,
          dashPattern: [3, 5]
        });
      }
    }

    // ===== 课程节点（外圈） =====
    const courseRadius: number = 3.8;
    for (let i: number = 0; i < courses.length; i++) {
      const course: CourseInfo = courses[i];
      const angle: number = (Math.PI * 2 * i) / courses.length + 0.6;
      const px: number = Math.cos(angle) * courseRadius;
      const py: number = (i - 1) * 0.8;
      const pz: number = Math.sin(angle) * courseRadius;

      const urgency: number = Math.max(0, 1 - course.exam.daysLeft / 30);
      const courseColor: string = urgency > 0.7 ? '#E04F5F' : (urgency > 0.3 ? '#FFA502' : '#2F7D6D');

      this.nodes.push({
        id: `course-${course.courseId}`,
        label: course.courseName,
        subLabel: `考试倒计时 ${course.exam.daysLeft} 天`,
        x: px, y: py, z: pz,
        radius: 13 + urgency * 5,
        color: courseColor,
        glowColor: courseColor === '#2F7D6D' ? 'rgba(47,125,109,0.35)' : 'rgba(224,79,95,0.3)',
        category: 'course',
        priority: Math.round(urgency * 100)
      });

      // 课程 → 中心
      this.edges.push({
        fromId: 'center',
        toId: `course-${course.courseId}`,
        color: '#2F7D6D',
        width: 2.0,
        dashPattern: []
      });

      // 课程 → 相关的薄弱点
      for (let w: number = 0; w < weaknesses.length; w++) {
        const weakNodeId: string = `weakness-${w}`;
        const weakNode: ModelNode | undefined = this.nodes.find((n: ModelNode) => n.id === weakNodeId);
        if (weakNode !== undefined && weakNode.subLabel.indexOf(course.courseName) !== -1) {
          this.edges.push({
            fromId: weakNodeId,
            toId: `course-${course.courseId}`,
            color: '#2F7D6D',
            width: 1.2,
            dashPattern: [5, 3]
          });
        }
      }

      // 课程 → 相关的DDL
      const courseDDLs: HomeworkDDL[] = ddls.filter((d: HomeworkDDL) => d.courseName === course.courseName);
      for (let d: number = 0; d < courseDDLs.length; d++) {
        this.edges.push({
          fromId: `ddl-${courseDDLs[d].id}`,
          toId: `course-${course.courseId}`,
          color: '#FFA502',
          width: 0.8,
          dashPattern: [8, 4]
        });
      }
    }

    // ===== 薄弱点之间的互补连线 =====
    for (let i: number = 0; i < weaknesses.length; i++) {
      for (let j: number = i + 1; j < weaknesses.length; j++) {
        const nodeI: ModelNode | undefined = this.nodes.find((n: ModelNode) => n.id === `weakness-${i}`);
        const nodeJ: ModelNode | undefined = this.nodes.find((n: ModelNode) => n.id === `weakness-${j}`);
        if (nodeI !== undefined && nodeJ !== undefined &&
          nodeI.subLabel !== '通用薄弱点' && nodeJ.subLabel !== '通用薄弱点' &&
          nodeI.subLabel === nodeJ.subLabel) {
          // 同课程的薄弱点互相连接
          this.edges.push({
            fromId: `weakness-${i}`,
            toId: `weakness-${j}`,
            color: 'rgba(224,79,95,0.25)',
            width: 0.6,
            dashPattern: [2, 8]
          });
        }
      }
    }
  }

  /**
   * 设置画布尺寸
   */
  setCanvasSize(width: number, height: number): void {
    this.width = width;
    this.height = height;
    this.centerX = width / 2;
    this.centerY = height / 2;
  }

  /**
   * 更新自动旋转
   */
  updateAutoRotate(): void {
    if (!this.isDragging) {
      // 缓慢趋向目标角度（惯性衰减）
      this.rotationY += this.autoRotateSpeed;
    }
  }

  /**
   * 处理触摸开始
   */
  onTouchStart(x: number, y: number): void {
    this.isDragging = true;
    this.lastTouchX = x;
    this.lastTouchY = y;
    this.targetRotationY = this.rotationY;
    this.targetRotationX = this.rotationX;
  }

  /**
   * 处理触摸移动
   */
  onTouchMove(x: number, y: number): void {
    if (!this.isDragging) {
      return;
    }
    const dx: number = x - this.lastTouchX;
    const dy: number = y - this.lastTouchY;

    this.rotationY += dx * 0.008;
    this.rotationX += dy * 0.008;

    // 限制X轴倾斜角度
    this.rotationX = Math.max(-1.2, Math.min(0.5, this.rotationX));

    this.lastTouchX = x;
    this.lastTouchY = y;
  }

  /**
   * 处理触摸结束
   */
  onTouchEnd(): void {
    this.isDragging = false;
  }

  /**
   * 放大
   */
  zoomIn(): void {
    this.zoomLevel = Math.min(this.maxZoom, this.zoomLevel + 0.2);
  }

  /**
   * 缩小
   */
  zoomOut(): void {
    this.zoomLevel = Math.max(this.minZoom, this.zoomLevel - 0.2);
  }

  /**
   * 获取当前缩放级别
   */
  getZoom(): number {
    return this.zoomLevel;
  }

  /**
   * 获取缩放百分比字符串
   */
  getZoomPercent(): string {
    return Math.round(this.zoomLevel * 100) + '%';
  }

  /**
   * 处理双指缩放开始
   */
  handlePinchStart(touch1X: number, touch1Y: number, touch2X: number, touch2Y: number): void {
    this.isPinching = true;
    this.isDragging = false;
    const dx: number = touch2X - touch1X;
    const dy: number = touch2Y - touch1Y;
    this.lastPinchDistance = Math.sqrt(dx * dx + dy * dy);
  }

  /**
   * 处理双指缩放更新
   */
  handlePinchUpdate(touch1X: number, touch1Y: number, touch2X: number, touch2Y: number): void {
    if (!this.isPinching) {
      return;
    }
    const dx: number = touch2X - touch1X;
    const dy: number = touch2Y - touch1Y;
    const currentDistance: number = Math.sqrt(dx * dx + dy * dy);

    if (this.lastPinchDistance > 0) {
      const scale: number = currentDistance / this.lastPinchDistance;
      this.zoomLevel = Math.max(this.minZoom, Math.min(this.maxZoom, this.zoomLevel * scale));
    }
    this.lastPinchDistance = currentDistance;
  }

  /**
   * 处理双指缩放结束
   */
  handlePinchEnd(): void {
    this.isPinching = false;
    this.lastPinchDistance = 0;
  }

  /**
   * 是否正在缩放
   */
  get isZoomInteracting(): boolean {
    return this.isPinching;
  }

  /**
   * 执行3D→2D透视投影，返回投影后的节点和边
   */
  project(): ProjectionResult {
    const projectedNodes: ProjectedNode[] = [];
    const projectedEdges: ProjectedEdge[] = [];

    // 旋转矩阵：绕Y轴旋转
    const cosY: number = Math.cos(this.rotationY);
    const sinY: number = Math.sin(this.rotationY);
    const cosX: number = Math.cos(this.rotationX);
    const sinX: number = Math.sin(this.rotationX);

    // 第一遍：投影所有节点
    const nodeMap: Map<string, ProjectedNode> = new Map();

    for (let i: number = 0; i < this.nodes.length; i++) {
      const node: ModelNode = this.nodes[i];

      // 绕Y轴旋转
      let rx: number = node.x * cosY - node.z * sinY;
      let rz: number = node.x * sinY + node.z * cosY;
      let ry: number = node.y;

      // 绕X轴旋转（轻微倾斜）
      const ry2: number = ry * cosX - rz * sinX;
      const rz2: number = ry * sinX + rz * cosX;

      // 透视投影（应用缩放级别）
      const baseScale: number = this.fov / (this.fov + rz2 + 5);
      const scale: number = baseScale * this.zoomLevel;
      const sx: number = rx * scale * 70 + this.centerX;
      const sy: number = ry2 * scale * 70 + this.centerY;
      const projectedRadius: number = node.radius * scale;

      const projected: ProjectedNode = {
        id: node.id,
        label: node.label,
        subLabel: node.subLabel,
        sx: sx,
        sy: sy,
        radius: Math.max(3, projectedRadius),
        color: node.color,
        glowColor: node.glowColor,
        depth: rz2 + 5,
        category: node.category
      };

      projectedNodes.push(projected);
      nodeMap.set(node.id, projected);
    }

    // 第二遍：投影所有边
    for (let i: number = 0; i < this.edges.length; i++) {
      const edge: ModelEdge = this.edges[i];
      const fromNode: ProjectedNode | undefined = nodeMap.get(edge.fromId);
      const toNode: ProjectedNode | undefined = nodeMap.get(edge.toId);

      if (fromNode !== undefined && toNode !== undefined) {
        const avgDepth: number = (fromNode.depth + toNode.depth) / 2;
        const opacity: number = Math.max(0.1, 1 - avgDepth / 8);

        projectedEdges.push({
          fromX: fromNode.sx,
          fromY: fromNode.sy,
          toX: toNode.sx,
          toY: toNode.sy,
          color: edge.color,
          width: edge.width,
          opacity: opacity,
          dashPattern: edge.dashPattern
        });
      }
    }

    // 按深度排序节点（远的先画）
    projectedNodes.sort((a: ProjectedNode, b: ProjectedNode) => b.depth - a.depth);

    const result: ProjectionResult = { nodes: projectedNodes, edges: projectedEdges };
    return result;
  }

  /**
   * 使用Canvas 2D上下文渲染整个3D场景
   */
  render(ctx: CanvasRenderingContext2D): void {
    // 清空画布
    ctx.clearRect(0, 0, this.width, this.height);

    const projectionResult: ProjectionResult = this.project();
    const projectedNodes: ProjectedNode[] = projectionResult.nodes;
    const projectedEdges: ProjectedEdge[] = projectionResult.edges;

    // 绘制背景粒子（远景星点效果）
    this.drawBackgroundParticles(ctx);

    // ===== 第一遍：绘制所有连线 =====
    for (let i: number = 0; i < projectedEdges.length; i++) {
      this.drawEdge(ctx, projectedEdges[i]);
    }

    // ===== 第二遍：绘制所有节点（按深度排序，近的在上） =====
    for (let i: number = 0; i < projectedNodes.length; i++) {
      this.drawNode(ctx, projectedNodes[i]);
    }
  }

  /**
   * 绘制背景粒子
   */
  private drawBackgroundParticles(ctx: CanvasRenderingContext2D): void {
    const particleCount: number = 30;
    ctx.fillStyle = 'rgba(47,125,109,0.08)';
    for (let i: number = 0; i < particleCount; i++) {
      // 使用固定种子模拟随机位置
      const px: number = ((i * 73 + 17) % 100) / 100 * this.width;
      const py: number = ((i * 137 + 31) % 100) / 100 * this.height;
      const size: number = ((i * 47 + 11) % 3) + 0.5;

      ctx.beginPath();
      ctx.arc(px, py, size, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  /**
   * 绘制连线
   */
  private drawEdge(ctx: CanvasRenderingContext2D, edge: ProjectedEdge): void {
    ctx.save();

    // 设置透明度
    ctx.globalAlpha = edge.opacity;

    // 设置虚线
    if (edge.dashPattern.length > 0) {
      ctx.setLineDash(edge.dashPattern);
    } else {
      ctx.setLineDash([]);
    }

    ctx.strokeStyle = edge.color;
    ctx.lineWidth = edge.width;
    ctx.lineCap = 'round';

    ctx.beginPath();
    ctx.moveTo(edge.fromX, edge.fromY);
    ctx.lineTo(edge.toX, edge.toY);
    ctx.stroke();

    ctx.restore();
  }

  /**
   * 绘制节点
   */
  private drawNode(ctx: CanvasRenderingContext2D, node: ProjectedNode): void {
    ctx.save();

    // 深度雾化效果
    const depthFade: number = Math.max(0.4, 1 - (node.depth - 1) / 8);
    ctx.globalAlpha = depthFade;

    // 发光光晕
    const glowGradient: CanvasGradient = ctx.createRadialGradient(
      node.sx, node.sy, 0,
      node.sx, node.sy, node.radius * 2.5
    );
    glowGradient.addColorStop(0, node.glowColor);
    glowGradient.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = glowGradient;
    ctx.beginPath();
    ctx.arc(node.sx, node.sy, node.radius * 2.5, 0, Math.PI * 2);
    ctx.fill();

    // 节点主体
    const bodyGradient: CanvasGradient = ctx.createRadialGradient(
      node.sx - node.radius * 0.3, node.sy - node.radius * 0.3, node.radius * 0.1,
      node.sx, node.sy, node.radius
    );
    bodyGradient.addColorStop(0, '#FFFFFF');
    bodyGradient.addColorStop(0.4, node.color);
    bodyGradient.addColorStop(1, this.darkenColor(node.color, 0.5));
    ctx.fillStyle = bodyGradient;
    ctx.beginPath();
    ctx.arc(node.sx, node.sy, node.radius, 0, Math.PI * 2);
    ctx.fill();

    // 节点边框
    ctx.strokeStyle = this.darkenColor(node.color, 0.3);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(node.sx, node.sy, node.radius, 0, Math.PI * 2);
    ctx.stroke();

    // 中心节点特殊处理：白色内环
    if (node.category === 'user') {
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 2;
      ctx.globalAlpha = depthFade * 0.7;
      ctx.beginPath();
      ctx.arc(node.sx, node.sy, node.radius - 5, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = depthFade;
    }

    // 节点标签（字体随缩放级别增大）
    const baseFontSize: number = node.category === 'user' ? 16 : (node.category === 'course' ? 14 : 12);
    const fontSize: number = baseFontSize * Math.max(0.7, this.zoomLevel);
    const labelOffset: number = node.radius + 14;

    ctx.fillStyle = node.category === 'user' ? '#2F7D6D' : '#1F2937';
    ctx.font = `bold ${fontSize}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    // 标签背景
    const textWidth: number = ctx.measureText(node.label).width;
    if (node.label.length > 0) {
      const bgPadding: number = 4;
      const bgX: number = node.sx - textWidth / 2 - bgPadding;
      const bgY: number = node.sy - labelOffset - fontSize / 2 - bgPadding;
      const bgW: number = textWidth + bgPadding * 2;
      const bgH: number = fontSize + bgPadding * 2;

      ctx.fillStyle = 'rgba(255,255,255,0.85)';
      ctx.globalAlpha = depthFade * 0.9;

      // 圆角矩形背景
      this.drawRoundRect(ctx, bgX, bgY, bgW, bgH, 4);
      ctx.fill();

      ctx.globalAlpha = depthFade;
    }

    ctx.fillStyle = node.category === 'user' ? '#2F7D6D' :
      (node.category === 'weakness' ? '#BE3144' :
        (node.category === 'ddl' ? '#CC6A00' : '#1F5F4E'));
    ctx.fillText(node.label, node.sx, node.sy - labelOffset);

    ctx.restore();
  }

  /**
   * 绘制圆角矩形
   */
  private drawRoundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arcTo(x + w, y, x + w, y + r, r);
    ctx.lineTo(x + w, y + h - r);
    ctx.arcTo(x + w, y + h, x + w - r, y + h, r);
    ctx.lineTo(x + r, y + h);
    ctx.arcTo(x, y + h, x, y + h - r, r);
    ctx.lineTo(x, y + r);
    ctx.arcTo(x, y, x + r, y, r);
  }

  /**
   * 颜色加深
   */
  private darkenColor(color: string, factor: number): string {
    // 简单处理十六进制颜色
    if (color.startsWith('#')) {
      const hex: string = color.replace('#', '');
      let r: number = 0;
      let g: number = 0;
      let b: number = 0;
      if (hex.length === 6) {
        r = parseInt(hex.substring(0, 2), 16);
        g = parseInt(hex.substring(2, 4), 16);
        b = parseInt(hex.substring(4, 6), 16);
      } else if (hex.length === 3) {
        r = parseInt(hex.charAt(0) + hex.charAt(0), 16);
        g = parseInt(hex.charAt(1) + hex.charAt(1), 16);
        b = parseInt(hex.charAt(2) + hex.charAt(2), 16);
      }
      r = Math.max(0, Math.floor(r * (1 - factor)));
      g = Math.max(0, Math.floor(g * (1 - factor)));
      b = Math.max(0, Math.floor(b * (1 - factor)));
      return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
    }
    return color;
  }

  /**
   * 重置旋转角度
   */
  resetRotation(): void {
    this.rotationY = 0.5;
    this.rotationX = -0.3;
    this.isDragging = false;
  }

  /**
   * 获取是否正在拖拽
   */
  get isUserInteracting(): boolean {
    return this.isDragging;
  }
}
