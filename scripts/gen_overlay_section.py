"""為 apply_android_overlay.ps1 產生一節「上游檔案補丁」，並驗證可逐字重現。

用法（在倉庫根目錄）：
  python scripts/gen_overlay_section.py "12. 標題" "說明一" "說明二" -- 檔案1 檔案2 ...

做法：以 HEAD 版本為「修改前」、工作區為「修改後」；相距 6 行以內的改動合併成
一整塊；錨點自動加上下文直到在檔內唯一；每段以自身替換文字作「已套用」標記
（含修改前不存在的新行，且一對一，不會被其他段遮蔽）。產生後先在記憶體中
依序套用並逐字比對修改後檔案，不一致即中止、不寫入腳本。

新增檔不在此處理：請加進腳本的 $overlayFiles 清單。

注意：較後的節若改動同一區域，可令較前節「以整塊替換文字作標記」不再連續出現，
-Check 會誤報待套用，實跑則會重複插入（2026-11-23 第 12／13 節即遇到）。新增一節後，
須以上一個 tag 的檔案為起點完整套用一次並逐字比對；遇此情況改用該段獨有的一行作標記。
"""
import difflib
import subprocess
import sys
from pathlib import Path

SCRIPT = Path('scripts/apply_android_overlay.ps1')
END = '# ================================================================ 結果'


def ps_str(text: str) -> str:
    lines = text.split('\n')
    quote = lambda line: "'" + line.replace("'", "''") + "'"
    if len(lines) == 1:
        return quote(lines[0])
    return '(@(\n' + ',\n'.join('    ' + quote(line) for line in lines) + '\n) -join $LF)'


def head(rel: str) -> str:
    out = subprocess.run(['git', 'show', 'HEAD:' + rel], capture_output=True, check=True)
    return out.stdout.decode('utf-8').replace('\r\n', '\n')


def work(rel: str) -> str:
    return Path(rel).read_bytes().decode('utf-8').replace('\r\n', '\n')


def grouped(a, b, gap=6):
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        if out and i1 - out[-1][1] <= gap:
            out[-1] = (out[-1][0], i2, out[-1][2], j2)
        else:
            out.append((i1, i2, j1, j2))
    return out


def patches(rel: str):
    before, after = head(rel), work(rel)
    a, b = before.split('\n'), after.split('\n')
    sim, result = before, []
    for i1, i2, j1, j2 in grouped(a, b):
        # 純刪除時替換文字只剩上文，必然已在檔內，「已套用」標記永不成立；
        # 故刪除段同時帶下文一行，令替換文字（上文＋下文相連）在修改前不存在。
        # 上文用盡（改動貼近檔首）時改為加長下文。
        base_post = 1 if j1 == j2 else 0
        step = 1
        while True:
            ctx = min(step, i1)
            post = base_post + (step - ctx)
            if i2 + post > len(a) or (ctx == 0 and post == 0):
                raise SystemExit(f'{rel}: 第 {i1 + 1} 行附近找不到唯一錨點／標記，已中止')
            anchor = '\n'.join(a[i1 - ctx:i2 + post])
            repl = '\n'.join(a[i1 - ctx:i1] + b[j1:j2] + a[i2:i2 + post])
            if before.count(anchor) == 1 and sim.count(anchor) == 1 and repl not in sim:
                break
            step += 1
        sim = sim.replace(anchor, repl)
        result.append((anchor, repl))
    if sim != after:
        raise SystemExit(f'{rel}: 補丁無法逐字重現修改後檔案，已中止')
    return result


def main(argv):
    if '--' not in argv or len(argv) < 3:
        raise SystemExit(__doc__)
    split = argv.index('--')
    title, notes, files = argv[0], argv[1:split], argv[split + 1:]
    code = [f'# ================================================================ {title}', '#']
    code += [f'# {n}' for n in notes]
    code += ['# 補丁由 scripts/gen_overlay_section.py 產生並驗證逐字重現。', '']
    count = 0
    for rel in files:
        name = Path(rel).name
        for k, (anchor, repl) in enumerate(patches(rel), 1):
            code.append(
                f"Patch-Overlay '{rel}' '{name}: {title.split('.', 1)[-1].strip()} {k}' `\n"
                f'    {ps_str(repl)} `\n    {ps_str(anchor)} `\n    {ps_str(repl)}\n'
            )
            count += 1
        print(f'{rel}: ok')
    raw = SCRIPT.read_bytes()
    bom, crlf = raw.startswith(b'\xef\xbb\xbf'), b'\r\n' in raw
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    if text.count(END) != 1 or f'# ================================================================ {title}' in text:
        raise SystemExit('腳本結構不符或此節已存在')
    text = text.replace(END, '\n'.join(code) + '\n' + END)
    out = text.replace('\n', '\r\n') if crlf else text
    SCRIPT.write_bytes((b'\xef\xbb\xbf' if bom else b'') + out.encode('utf-8'))
    print(f'寫入 {count} 段補丁')


if __name__ == '__main__':
    main(sys.argv[1:])
