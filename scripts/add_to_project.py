import sys, re, hashlib

def add_file(filepath, group_name="Preferences"):
    filename = filepath.split('/')[-1]
    
    # 24-char hex IDs
    h1 = hashlib.md5((filename + "_fileref").encode()).hexdigest()[:24].upper()
    h2 = hashlib.md5((filename + "_buildfile").encode()).hexdigest()[:24].upper()
    
    with open("Chatmice.xcodeproj/project.pbxproj", "r") as f:
        content = f.read()
        
    if filename in content:
        print(f"File {filename} already in project.pbxproj")
        return
        
    # 1. PBXBuildFile
    build_file_entry = f"\t\t{h2} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {h1} /* {filename} */; }};\n"
    content = content.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n" + build_file_entry)
    
    # 2. PBXFileReference
    file_ref_entry = f"\t\t{h1} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = \"<group>\"; }};\n"
    content = content.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + file_ref_entry)
    
    # 3. Add to Group
    group_pattern = rf"(\w+ /\* {group_name} \*/ = {{\s+isa = PBXGroup;\s+children = \()"
    m = re.search(group_pattern, content)
    if not m:
        print(f"Error: Group {group_name} not found")
        sys.exit(1)
    matched_str = m.group(1)
    content = content.replace(matched_str, matched_str + f"\n\t\t\t\t{h1} /* {filename} */,")
    
    # 4. Add to Sources build phase
    sources_pattern = r"(\w+ /\* Sources \*/ = \{\s+isa = PBXSourcesBuildPhase;\s+buildActionMask = \d+;\s+files = \()"
    m2 = re.search(sources_pattern, content)
    if not m2:
        print("Error: Sources build phase not found")
        sys.exit(1)
    matched_sources = m2.group(1)
    content = content.replace(matched_sources, matched_sources + f"\n\t\t\t\t{h2} /* {filename} in Sources */,")
    
    with open("Chatmice.xcodeproj/project.pbxproj", "w") as f:
        f.write(content)
        
    print(f"Successfully added {filename} to {group_name} in project.pbxproj")

if __name__ == "__main__":
    if len(sys.argv) > 2:
        add_file(sys.argv[1], sys.argv[2])
    elif len(sys.argv) > 1:
        add_file(sys.argv[1])
