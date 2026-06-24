"""
Nazi Zombies: Portable QuakeC CRC generator (Dependency-free version)

Takes input .CSV files and outputs an FTEQCC-compilable
QuakeC struct with its contents, always assumes the first
entry should be IBM 3740 CRC16 hashed, adding its length
as an entry as well, for collision detection.
"""

import argparse
import sys
import os
import csv
from dataclasses import dataclass

args = {}
struct_fields = []
original_lengths = []
original_names = []

ITYPE_FLOAT = 0
ITYPE_STRING = 1
ITYPE_CRC = 2

@dataclass
class StructField:
    '''
    Class for fields that are added to the QuakeC struct.
    '''
    name: str
    item_type: int = ITYPE_FLOAT

def crc16_ibm_3740(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= (byte << 8)
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc = crc << 1
            crc &= 0xFFFF
    return crc

def write_qc_file(csv_data):
    '''
    Writes the data obtained into an FTEQCC-compilable
    struct.
    '''
    with open(args['output_file'], 'w') as output:
        # Define the struct.
        output.write('var struct {\n')

        # Write out all of it's types..
        for fields in struct_fields:
            if fields.item_type == ITYPE_STRING:
                output.write('string ')
            else:
                output.write('float ')

            output.write(f'{fields.name};\n')
        
        # Close the struct.
        output.write('}')

        # Now, the name of it
        struct_name = args['struct_name']
        output.write(f'{struct_name}[]=')
        output.write('{\n')

        # We can begin writing the actual data..
        value_counter = 0
        for value in csv_data.values:
            output.write('{')
            entry_counter = 0
            for entry in value:
                if struct_fields[entry_counter].item_type != ITYPE_STRING:
                    output.write(f'{str(entry)},')
                else:
                    output.write(f'\"{entry}\",')
                entry_counter += 1

            # Write the length of the first entry
            output.write(str(original_lengths[value_counter]))

            # Close entry, add comma if not the last..
            output.write('}')
            if value_counter + 1 < len(csv_data.values):
                output.write(',')

            # Leave comment referring to the unhashed-value
            output.write(f' // {original_names[value_counter]}')

            output.write('\n')

            value_counter += 1

        # End struct!
        output.write('};\n')

def create_qc_structfields(csv_data):
    '''
    Parses the .CSV data to create new StructField
    entries given the .CSV specific requirements.
    '''
    global struct_fields

    column_count = 0
    for column in csv_data.columns:
        # Assume first entry is what we always want
        # to hash, append _crc to it, too.
        if column_count == 0:
            item_type = ITYPE_CRC
            item_name = column + '_crc'
        else:
            item_type = ITYPE_STRING
            item_name = column
        struct_fields.append(StructField(item_name, item_type))
        column_count += 1

    # Always append a field that will store the
    # length of the unhashed-CRC.
    struct_fields.append(StructField('crc_strlen', ITYPE_FLOAT))

def generate_qc_file(csv_data):
    '''
    Calls for population of StructFields and prompts
    for writing the .QC file output.
    '''
    create_qc_structfields(csv_data)
    write_qc_file(csv_data)

def read_csv_data():
    '''
    Parses the input_file .CSV, performs the hashing on the first indexes,
    and sorts in ascending order.
    '''
    global original_lengths, original_names
    
    rows = []
    with open(args['input_file'], mode='r', newline='', encoding='utf-8') as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            if not row:
                continue
            rows.append(row)
            
    processed_rows = []
    for row in rows:
        val0 = row[0]
        original_lengths.append(len(val0))
        original_names.append(val0)
        
        # Calculate crc
        crc = crc16_ibm_3740(val0.encode('utf-8'))
        row_copy = list(row)
        row_copy[0] = crc
        processed_rows.append(row_copy)
        
    # Sort everything by ascending order based on the first column (CRC).
    zipped = list(zip(processed_rows, original_lengths, original_names))
    zipped.sort(key=lambda x: x[0][0])
    
    sorted_rows = [x[0] for x in zipped]
    original_lengths = [x[1] for x in zipped]
    original_names = [x[2] for x in zipped]
    
    class PandasLike:
        def __init__(self, values, columns):
            self.values = values
            self.columns = columns
            
    return PandasLike(sorted_rows, header)

def fetch_cli_arguments():
    '''
    Initiates ArgParser with all potential command line arguments.
    '''
    global args
    parser = argparse.ArgumentParser(description='IBM 3740 CRC16 hash generator in FTE QuakeC-readable data structure.')
    parser.add_argument('-i', '--input-file',
                        help='.CSV input file to parse.', required=True)
    parser.add_argument('-o', '--output-file',
                        help='File name for generated .QC file.', default='hashes.qc')
    parser.add_argument('-n', '--struct-name',
                        help='Name of the struct generated.', default='asset_conversion_table')
    args = vars(parser.parse_args())

def main():
    fetch_cli_arguments()

    if not os.path.isfile(args['input_file']):
        print('Error: Input .CSV file does not exist. Exiting.')
        sys.exit()

    csv_data = read_csv_data()
    generate_qc_file(csv_data)

if __name__ == '__main__':
    main()
