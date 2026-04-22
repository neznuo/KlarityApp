import re
import glob

for filepath in glob.glob("/Users/rahulmohandas/Documents/Projects/KlarityApp/backend/app/models/*.py"):
    with open(filepath, "r") as f:
        content = f.read()
        
    old_content = content
    content = re.sub(r'Mapped\[([a-zA-Z_]+)\s*\|\s*None\]', r'Mapped[Optional[\1]]', content)
    
    if content != old_content:
        if 'from typing import ' in content and 'Optional' not in content:
            content = content.replace('from typing import ', 'from typing import Optional, ')
        elif 'from typing import ' not in content:
            if 'from sqlalchemy' in content:
                content = content.replace('from sqlalchemy', 'from typing import Optional\nfrom sqlalchemy', 1)
            else:
                content = 'from typing import Optional\n' + content
        with open(filepath, "w") as f:
            f.write(content)
        print(f"Fixed {filepath}")
