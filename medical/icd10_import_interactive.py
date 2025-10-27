#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Interactive ICD-10 Data Import Script for Odoo Docker Deployments
Author: ghoat debug innovus.co.ke
Maintained by: makondoo.org

This script helps import official ICD-10 diagnosis codes into any Odoo HIS system
running in Docker containers.
"""

import os
import sys
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

def print_header():
    print(f"{Colors.HEADER}{Colors.BOLD}")
    print("=" * 70)
    print("    ICD-10 Data Import Tool for Odoo HIS Systems")
    print("    Author: ghoat debug innovus.co.ke")
    print("    Maintained by: makondoo.org")
    print("=" * 70)
    print(f"{Colors.ENDC}")

def print_success(message):
    print(f"{Colors.OKGREEN}✓ {message}{Colors.ENDC}")

def print_error(message):
    print(f"{Colors.FAIL}✗ {message}{Colors.ENDC}")

def print_warning(message):
    print(f"{Colors.WARNING}⚠ {message}{Colors.ENDC}")

def print_info(message):
    print(f"{Colors.OKBLUE}ℹ {message}{Colors.ENDC}")

def get_user_input(prompt, default=None):
    if default:
        user_input = input(f"{prompt} [{default}]: ").strip()
        return user_input if user_input else default
    return input(f"{prompt}: ").strip()

def check_docker():
    """Check if Docker is available"""
    try:
        subprocess.run(['docker', '--version'], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def list_docker_containers():
    """List running Docker containers"""
    try:
        result = subprocess.run(['docker', 'ps', '--format', 'table {{.Names}}\t{{.Image}}\t{{.Status}}'], 
                              capture_output=True, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError:
        return None

def validate_xml_file(file_path):
    """Validate if file is a proper ICD-10 XML file"""
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        
        # Check if it's ICD-10 format
        if root.tag in ['ICD10CM.tabular', 'ICD10CM.index']:
            return True, root.tag
        
        # Check for ICD-10 content
        if 'icd' in file_path.lower() and root.find('.//chapter') is not None:
            return True, 'tabular'
        
        return False, None
    except Exception as e:
        return False, str(e)

def find_xml_files(directory):
    """Find potential ICD-10 XML files in directory"""
    xml_files = []
    directory = Path(directory)
    
    if not directory.exists():
        return xml_files
    
    for file_path in directory.rglob("*.xml"):
        if 'icd' in file_path.name.lower():
            is_valid, file_type = validate_xml_file(file_path)
            if is_valid:
                xml_files.append((str(file_path), file_type))
    
    return xml_files

def generate_import_script(container_name, database_name, xml_file_path):
    """Generate the import script for execution"""
    return f'''
import sys
sys.path.append('/usr/lib/python3/dist-packages')
import odoo
from odoo.api import Environment
import xml.etree.ElementTree as ET

# Connect to database
odoo.tools.config.parse_config([])
odoo.tools.config['db_name'] = '{database_name}'

registry = odoo.registry('{database_name}')
with registry.cursor() as cr:
    env = Environment(cr, 1, {{}})
    
    diagnosis_model = env['his.icd.diagnosis']
    xml_file = '{xml_file_path}'
    
    print('Starting ICD-10 import...')
    
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        
        imported = 0
        updated = 0
        
        for chapter in root.findall('.//chapter'):
            chapter_name = chapter.find('desc').text if chapter.find('desc') is not None else ''
            print(f'Processing: {{chapter_name}}')
            
            for section in chapter.findall('.//section'):
                for diag in section.findall('.//diag'):
                    code_elem = diag.find('name')
                    desc_elem = diag.find('desc')
                    
                    if code_elem is not None and desc_elem is not None:
                        code = code_elem.text.strip() if code_elem.text else ''
                        description = desc_elem.text.strip() if desc_elem.text else ''
                        
                        if code and description:
                            existing = diagnosis_model.search([('code', '=', code), ('icd_version', '=', 'icd10')], limit=1)
                            
                            vals = {{
                                'name': description,
                                'code': code,
                                'icd_version': 'icd10',
                                'description': description,
                                'category': chapter_name,
                                'active': True,
                            }}
                            
                            if existing:
                                existing.write(vals)
                                updated += 1
                            else:
                                diagnosis_model.create(vals)
                                imported += 1
                            
                            if (imported + updated) % 100 == 0:
                                print(f'  Processed {{imported + updated}} records...')
        
        cr.commit()
        print(f'Import completed: {{imported}} created, {{updated}} updated')
        
    except Exception as e:
        print(f'Error: {{str(e)}}')
        cr.rollback()
        raise
'''

def main():
    print_header()
    
    # Check Docker
    if not check_docker():
        print_error("Docker is not installed or not running!")
        print_info("Please install Docker and make sure it's running.")
        sys.exit(1)
    
    print_success("Docker is available")
    
    # List containers
    print_info("Listing running Docker containers...")
    containers = list_docker_containers()
    if containers:
        print(containers)
    else:
        print_warning("No running containers found or unable to list containers")
    
    # Get container name
    container_name = get_user_input("Enter your Odoo Docker container name")
    if not container_name:
        print_error("Container name is required!")
        sys.exit(1)
    
    # Test container connection
    try:
        result = subprocess.run(['docker', 'exec', container_name, 'echo', 'test'], 
                              capture_output=True, check=True)
        print_success(f"Successfully connected to container: {container_name}")
    except subprocess.CalledProcessError:
        print_error(f"Cannot connect to container: {container_name}")
        print_info("Make sure the container name is correct and running")
        sys.exit(1)
    
    # Get database name
    database_name = get_user_input("Enter your Odoo database name", "sipital")
    
    # Get XML file path
    print_info("You need to provide the path to your ICD-10 XML file(s)")
    print_info("The file should be accessible from within the Docker container")
    
    xml_path = get_user_input("Enter path to ICD-10 XML file or directory")
    if not xml_path:
        print_error("XML file path is required!")
        sys.exit(1)
    
    # Check if it's a directory or file
    is_directory = get_user_input("Is this a directory? (y/n)", "n").lower() == 'y'
    
    if is_directory:
        print_info("Searching for ICD-10 XML files in directory...")
        # We can't check from host, so we'll assume user knows what they're doing
        xml_files = [xml_path]
    else:
        xml_files = [xml_path]
    
    # Confirm before proceeding
    print_info("Import Configuration:")
    print(f"  Container: {container_name}")
    print(f"  Database: {database_name}")
    print(f"  XML Path: {xml_path}")
    
    confirm = get_user_input("Proceed with import? (y/n)", "y").lower()
    if confirm != 'y':
        print_info("Import cancelled by user")
        sys.exit(0)
    
    # Generate and execute import script
    print_info("Generating import script...")
    import_script = generate_import_script(container_name, database_name, xml_path)
    
    # Write script to temporary file
    script_file = "/tmp/icd10_import_temp.py"
    with open(script_file, 'w') as f:
        f.write(import_script)
    
    print_info("Starting ICD-10 import process...")
    print_warning("This may take several minutes depending on the file size...")
    
    try:
        # Copy script to container and execute
        subprocess.run(['docker', 'cp', script_file, f'{container_name}:/tmp/icd10_import_temp.py'], check=True)
        
        # Execute the import
        result = subprocess.run([
            'docker', 'exec', container_name, 
            'python3', '/tmp/icd10_import_temp.py'
        ], text=True, capture_output=False)
        
        if result.returncode == 0:
            print_success("ICD-10 import completed successfully!")
            print_info("You can now use ICD-10 diagnosis codes in your HIS system")
        else:
            print_error("Import failed with errors")
            
    except subprocess.CalledProcessError as e:
        print_error(f"Import failed: {e}")
    except KeyboardInterrupt:
        print_warning("Import interrupted by user")
    finally:
        # Cleanup
        try:
            os.remove(script_file)
            subprocess.run(['docker', 'exec', container_name, 'rm', '-f', '/tmp/icd10_import_temp.py'], 
                         capture_output=True)
        except:
            pass
    
    print_info("Import process completed")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print_warning("\nProcess interrupted by user")
        sys.exit(1)
    except Exception as e:
        print_error(f"Unexpected error: {e}")
        sys.exit(1)
