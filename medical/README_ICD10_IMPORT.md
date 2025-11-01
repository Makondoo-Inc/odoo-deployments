# ICD-10 Data Import Tool for Odoo HIS Systems

**Author:** Makondoo Inc 
**Maintained by:** makondoo.org

## Overview

This interactive script helps you import official ICD-10 diagnosis codes into any Odoo HIS (Hospital Information System) running in Docker containers. It supports both ICD-10-CM tabular and index XML formats. https://www.cms.gov/medicare/coding-billing/icd-10-codes

Alternatively check out this tho no implemantation for its import is present https://gist.githubusercontent.com/cryocaustik/b86de96e66489ada97c25fc25f755de0/raw/b31a549638a609004e9a45f8933c3f37bdf4c27d/icd10_codes.json

## Prerequisites

- Docker installed and running
- Odoo HIS system running in Docker container
- ICD-10 XML data files (official format)
- Python 3.6+ on host system

## Quick Start

1. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/Makondoo-Inc/odoo-deployments/refs/heads/main/medical/icd10_import_interactive.py
   # OR copy the script to your system
   ```

2. **Make it executable optional will still run:**
   ```bash
   chmod +x icd10_import_interactive.py
   ```

3. **Run the interactive import:**
   ```bash
   python3 icd10_import_interactive.py
   ```

## What You'll Need

### 1. Docker Container Information
- **Container Name**: Your Odoo Docker container name (e.g., `my-odoo-container`)
- **Database Name**: Your Odoo database name (e.g., `hospital_db`)

### 2. ICD-10 XML Files
You need official ICD-10 XML files in one of these formats:
- **Tabular format**: `icd10cm_tabular_2026.xml`
- **Index format**: `icd10cm_index_2026.xml`
- **Drug/Neoplasm tables**: `icd10cm_drug_2026.xml`, `icd10cm_neoplasm_2026.xml`

### 3. File Location
The XML files must be accessible from within your Docker container. Common locations:
- `/mnt/data/icd10/` (if you have a mounted volume)
- `/tmp/icd10/` (if you copy files to container)
- `/opt/odoo/data/` (custom mount point)

## Step-by-Step Usage

### Step 1: Prepare Your Files
```bash
# Option 1: Copy files to container
docker cp icd10cm_tabular_2026.xml my-odoo-container:/tmp/

# Option 2: Use mounted volume (recommended)
# Place files in your mounted directory
```

### Step 2: Run the Script
```bash
python3 icd10_import_interactive.py
```

### Step 3: Follow the Prompts
The script will ask for:
1. **Container name** - Your Odoo Docker container
2. **Database name** - Your Odoo database (default: sipital)
3. **XML file path** - Path to your ICD-10 XML file(s)
4. **Confirmation** - Review settings before import

### Example Session
```
======================================================================
    ICD-10 Data Import Tool for Odoo HIS Systems
    Author: ghoat debug innovus.co.ke
    Maintained by: makondoo.org
======================================================================

✓ Docker is available
ℹ Listing running Docker containers...
NAMES                    IMAGE           STATUS
my-odoo-container       odoo:18.0       Up 2 hours

Enter your Odoo Docker container name: my-odoo-container
✓ Successfully connected to container: my-odoo-container

Enter your Odoo database name [sipital]: hospital_db

ℹ You need to provide the path to your ICD-10 XML file(s)
ℹ The file should be accessible from within the Docker container
Enter path to ICD-10 XML file or directory: /tmp/icd10cm_tabular_2026.xml

Is this a directory? (y/n) [n]: n

ℹ Import Configuration:
  Container: my-odoo-container
  Database: hospital_db
  XML Path: /tmp/icd10cm_tabular_2026.xml

Proceed with import? (y/n) [y]: y

ℹ Starting ICD-10 import process...
⚠ This may take several minutes depending on the file size...

Starting ICD-10 import...
Processing: Certain infectious and parasitic diseases (A00-B99)
  Processed 100 records...
  Processed 200 records...
...
Import completed: 46881 created, 0 updated

✓ ICD-10 import completed successfully!
ℹ You can now use ICD-10 diagnosis codes in your HIS system
```

## Supported File Formats

### ICD-10-CM Tabular (Recommended)
- Contains complete diagnosis codes with descriptions
- Organized by chapters and sections
- Example: `icd10cm_tabular_2026.xml`

### ICD-10-CM Index
- Contains cross-references and alternative terms
- Useful for comprehensive code coverage
- Example: `icd10cm_index_2026.xml`

### Specialized Tables
- Drug and chemical poisoning codes
- Neoplasm classification codes
- External cause codes

## Troubleshooting

### Common Issues

1. **Container not found**
   ```
   ✗ Cannot connect to container: my-container
   ```
   - Check container name with `docker ps`
   - Ensure container is running

2. **File not found**
   ```
   Error: [Errno 2] No such file or directory
   ```
   - Verify file path within container
   - Use `docker exec container ls /path/` to check

3. **Database connection error**
   ```
   Error: database "mydb" does not exist
   ```
   - Check database name
   - Ensure Odoo is properly configured

4. **Permission denied**
   ```
   Error: Permission denied
   ```
   - Check file permissions
   - Ensure Docker has access to files

### Getting Help

1. **Check container logs:**
   ```bash
   docker logs my-odoo-container
   ```

2. **Test container access:**
   ```bash
   docker exec my-odoo-container ls -la /tmp/
   ```

3. **Verify database:**
   ```bash
   docker exec my-odoo-container odoo shell -d your_db --shell-interface python3
   ```

## Advanced Usage

### Batch Import Multiple Files
```bash
# Place all XML files in a directory
docker cp icd10_files/ my-container:/tmp/icd10/

# Run script and specify directory
# Enter: /tmp/icd10/
# Select: y (for directory)
```

### Custom Docker Setup
```bash
# For custom Odoo installations
docker exec -e PYTHONPATH=/custom/path my-container python3 /tmp/import_script.py
```

## What Gets Imported

The script imports diagnosis records with:
- **Code**: Official ICD-10 code (A00.0, C78.5, etc.)
- **Name**: Full diagnosis description
- **Category**: Chapter classification
- **ICD Version**: Set to 'icd10'
- **Active**: All records active by default

## Post-Import

After successful import:
1. **Verify data**: Check HIS → Configuration → ICD Diagnoses
2. **Test usage**: Create radiology/lab requests with diagnoses
3. **Backup database**: Save your data after successful import

## Support

For issues or questions:
- **Technical Support**: ctf-1@makondoo.org
- **Documentation**: N/A
- **GitHub Issues**: [Create an issue](https://github.com/Makondoo-Inc/odoo-deployments/issues)

## License

This tool is provided as-is for developers of healthcare organizations implementing Odoo HIS systems.
