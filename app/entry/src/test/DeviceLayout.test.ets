import { describe, expect, it } from '@ohos/hypium';
import { DeviceLayout } from '../main/ets/utils/DeviceLayout';

/**
 * 布局断点判定。
 *
 * 背景：`module.json5` 声明了 `deviceTypes: ["phone", "tablet", "2in1"]`，
 * 但页面原先全按手机写死。`DeviceLayout` 是集中判定档位的地方，
 * 判定错了会导致大屏上该限宽的地方没限宽（或反过来）。所以这里把边界值钉死。
 */
export default function deviceLayoutTest() {
  describe('deviceLayoutTest', () => {
    it('classifies phone below 600vp', 0, () => {
      expect(DeviceLayout.classify(360)).assertEqual(DeviceLayout.PHONE);
      expect(DeviceLayout.classify(599)).assertEqual(DeviceLayout.PHONE);
    });

    it('classifies tablet from 600vp', 0, () => {
      expect(DeviceLayout.classify(600)).assertEqual(DeviceLayout.TABLET);
      expect(DeviceLayout.classify(839)).assertEqual(DeviceLayout.TABLET);
    });

    it('classifies desktop from 840vp', 0, () => {
      expect(DeviceLayout.classify(840)).assertEqual(DeviceLayout.DESKTOP);
      expect(DeviceLayout.classify(1920)).assertEqual(DeviceLayout.DESKTOP);
    });

    it('falls back to phone for invalid width', 0, () => {
      expect(DeviceLayout.classify(0)).assertEqual(DeviceLayout.PHONE);
      expect(DeviceLayout.classify(-1)).assertEqual(DeviceLayout.PHONE);
    });

    it('update records width and switches breakpoint', 0, () => {
      DeviceLayout.update(1024);
      expect(DeviceLayout.current()).assertEqual(DeviceLayout.DESKTOP);
      expect(DeviceLayout.isLargeScreen()).assertTrue();
      expect(DeviceLayout.windowWidth()).assertEqual(1024);

      DeviceLayout.update(400);
      expect(DeviceLayout.current()).assertEqual(DeviceLayout.PHONE);
      expect(DeviceLayout.isLargeScreen()).assertFalse();
    });

    it('ignores invalid update without clobbering state', 0, () => {
      DeviceLayout.update(700);
      expect(DeviceLayout.current()).assertEqual(DeviceLayout.TABLET);
      DeviceLayout.update(0);
      expect(DeviceLayout.current()).assertEqual(DeviceLayout.TABLET);
    });

    it('caps content width on large screens and leaves phones unconstrained', 0, () => {
      DeviceLayout.update(1024);
      expect(DeviceLayout.contentMaxWidth()).assertEqual(DeviceLayout.CONTENT_MAX_WIDTH);

      DeviceLayout.update(360);
      // 手机上必须是一个**有限**的宽值（Infinity 不是合法 Length，会让布局异常）
      expect(DeviceLayout.contentMaxWidth()).assertLarger(DeviceLayout.CONTENT_MAX_WIDTH);
      expect(DeviceLayout.contentMaxWidth() < 100000).assertTrue();
    });

    it('describes the current form factor in Chinese', 0, () => {
      DeviceLayout.update(400);
      expect(DeviceLayout.describe().indexOf('手机') >= 0).assertTrue();
      DeviceLayout.update(1024);
      expect(DeviceLayout.describe().indexOf('桌面') >= 0).assertTrue();
    });
  });
}
