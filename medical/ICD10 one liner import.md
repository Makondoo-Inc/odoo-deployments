# ICD-10 Import Guide for Odoo (tested on v18)

## Quick Import Script

This one-liner helps you import ICD-10 codes into Odoo with ease.

### Prerequisites

1. Download the latest ICD-10 codes XML file from the [CMS Medicare ICD-10 Codes website](https://www.cms.gov/medicare/coding-billing/icd-10-codes)
2. Place the XML file in an accessible location within your Odoo container
3. Ensure you have admin access to your Odoo database

### Usage

Run the following command from your host machine (not inside the container):

```bash
docker exec <your-container-name> python3 -c "
import sys
sys.path.append('/usr/lib/python3/dist-packages')
import odoo
from odoo.api import Environment
import xml.etree.ElementTree as ET

# Connect to existing database
odoo.tools.config.parse_config([])
odoo.tools.config['db_name'] = '<your-database-name>'
registry = odoo.registry('<your-database-name>')

with registry.cursor() as cr:
    env = Environment(cr, 1, {})  # Use user ID 1 (admin)
    
    diagnosis_model = env['his.icd.diagnosis']
    xml_file = '<path-to-your-xml-file>'
    
    print('Starting ICD-10 import...')
    
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        
        imported = 0
        
        for chapter in root.findall('.//chapter'):
            chapter_name = chapter.find('desc').text if chapter.find('desc') is not None else ''
            print(f'Processing: {chapter_name}')
            
            for section in chapter.findall('.//section'):
                for diag in section.findall('.//diag'):
                    code_elem = diag.find('name')
                    desc_elem = diag.find('desc')
                    
                    if code_elem is not None and desc_elem is not None:
                        code = code_elem.text.strip() if code_elem.text else ''
                        description = desc_elem.text.strip() if desc_elem.text else ''
                        
                        if code and description:
                            existing = diagnosis_model.search([('code', '=', code), ('icd_version', '=', 'icd10')], limit=1)
                            if not existing:
                                diagnosis_model.create({
                                    'name': description,
                                    'code': code,
                                    'icd_version': 'icd10',
                                    'description': description,
                                    'category': chapter_name,
                                    'active': True,
                                })
                                imported += 1
                                if imported % 50 == 0:
                                    print(f'  Imported {imported} records...')
        
        cr.commit()
        print(f'Import completed: {imported} ICD-10 codes imported')
        
    except Exception as e:
        print(f'Error: {str(e)}')
        cr.rollback()
        raise
"
```

### Configuration

Replace the following placeholders in the script:

- `<your-container-name>` - Name of your Odoo Docker container
- `<your-database-name>` - Your Odoo database name (appears twice in the script)
- `<path-to-your-xml-file>` - Full path to the ICD-10 XML file inside the container (e.g., `/mnt/custom-addons/icd10cm_tabular_2026.xml`)

### Example

```bash
docker exec my-odoo-container python3 -c "..."
```

### What It Does

- Parses the ICD-10 XML file structure (chapters, sections, diagnoses)
- Imports diagnosis codes with their descriptions and categories
- Skips duplicate entries (checks existing codes)
- Shows progress every 50 records
- Commits all changes to the database upon successful completion
- Rolls back changes if an error occurs

### Notes

- The script uses admin user (ID: 1) for the import
- Progress is displayed in the console
- Existing codes are not duplicated
- All imported codes are marked as active by default
