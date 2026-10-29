import re

with open("Sources/AiKeyboardLight/App/AppState.swift", "r") as f:
    lines = f.readlines()

new_lines = []
skip = False
for i, line in enumerate(lines):
    
    if "// AIObserverDelegate" in line:
        skip = True
    
    if skip:
        continue
    
    new_lines.append(line)

new_lines.append("}\n")

with open("Sources/AiKeyboardLight/App/AppState.swift", "w") as f:
    f.writelines(new_lines)
