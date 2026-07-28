require 'sketchup.rb'
require 'json'
require 'csv'

module AJ
  module DynamicCabinetCreator
    
    class CabinetManager
      
      def initialize
        @dialogs = {}
        @cabinet_counter = 0
        @deleted_cabinet_numbers = []
        @panel_counter = 0
        @deleted_panel_numbers = []
        @last_selection_time = {}
        @last_selected_entity = nil
        @update_property_panel_on_selection = false
        @selection_observer = CabinetSelectionObserver.new(self)
        Sketchup.active_model.selection.add_observer(@selection_observer)
      end

      # Enable/disable auto-update of property panel on selection
      def update_property_panel_on_selection
        @update_property_panel_on_selection
      end
      
      def update_property_panel_on_selection=(value)
        @update_property_panel_on_selection = value
      end
      
      # Check if entity was double-clicked and update tracking
      def check_double_click(entity)
        current_time = Time.now
        is_double_click = false
        
        # Check if this is a double-click (same entity selected within 0.5 seconds)
        if @last_selected_entity == entity
          last_time = @last_selection_time[entity.object_id]
          if last_time && (current_time - last_time) < 0.5  # 500ms double-click window
            is_double_click = true
          end
        end
        
        # Update tracking
        @last_selected_entity = entity
        @last_selection_time[entity.object_id] = current_time
        
        is_double_click
      end
      
      # Get next available cabinet number
      def get_next_cabinet_number
        used_numbers = current_cabinet_numbers

        if used_numbers.any?
          @cabinet_counter = [@cabinet_counter, used_numbers.max].max
        end

        if @deleted_cabinet_numbers.any?
          @deleted_cabinet_numbers.sort!
          while @deleted_cabinet_numbers.any?
            candidate = @deleted_cabinet_numbers.shift
            next if used_numbers.include?(candidate)
            return candidate
          end
        end

        loop do
          @cabinet_counter += 1
          return @cabinet_counter unless used_numbers.include?(@cabinet_counter)
        end
      end
      
      # Track deleted cabinet for number reuse
      def register_deleted_cabinet(cabinet_number)
        return unless cabinet_number

        number = cabinet_number.to_i
        return if number <= 0
        return if current_cabinet_numbers.include?(number)

        @deleted_cabinet_numbers << number unless @deleted_cabinet_numbers.include?(number)
      end
      
      # Show Cabinet Setup Dialog
      def show_cabinet_setup_dialog
        dialog = get_or_create_dialog('cabinet_setup', 'Cabinet Setup', 450, 550)
        dialog.set_url(File.join(__dir__, 'ui', 'cabinet_setup.html'))
        
        # Callback to get selected cabinet properties (checks current selection dynamically)
        dialog.add_action_callback('getSelectedCabinetProperties') do |action_context|
          model = Sketchup.active_model
          selection = model.selection.first
          selected_cabinet = is_cabinet_group?(selection) ? selection : nil
          
          if selected_cabinet
            # Get current cabinet properties
            cabinet_name = selected_cabinet.get_attribute('DCC', 'cabinet_name') || 'Unknown'
            width = selected_cabinet.get_attribute('DCC', 'width')
            depth = selected_cabinet.get_attribute('DCC', 'depth')
            height = selected_cabinet.get_attribute('DCC', 'height')
            panel_thickness = selected_cabinet.get_attribute('DCC', 'panel_thickness')
            back_thickness = selected_cabinet.get_attribute('DCC', 'back_thickness')
            back_inset = selected_cabinet.get_attribute('DCC', 'back_inset')
            panel_overlap = selected_cabinet.get_attribute('DCC', 'panel_overlap') || 'none'
            support_panel_count = selected_cabinet.get_attribute('DCC', 'support_panel_count') || 0
            support_panel_height = selected_cabinet.get_attribute('DCC', 'support_panel_height') || 100.mm
            support_panel_orientation = selected_cabinet.get_attribute('DCC', 'support_panel_orientation') || 'vertical'
            
            # Convert to mm for display
            width_mm = width ? width.to_mm.round(1) : 0
            depth_mm = depth ? depth.to_mm.round(1) : 0
            height_mm = height ? height.to_mm.round(1) : 0
            panel_thickness_mm = panel_thickness ? panel_thickness.to_mm.round(1) : 18
            back_thickness_mm = back_thickness ? back_thickness.to_mm.round(1) : 10
            back_inset_mm = back_inset ? back_inset.to_mm.round(1) : 18
            support_panel_count_int = support_panel_count.to_i
            support_panel_height_mm = support_panel_height ? support_panel_height.to_mm.round(1) : 100
            
            # Escape cabinet name for JavaScript
            cabinet_name_escaped = cabinet_name.gsub("'", "\\'").gsub("\n", "\\n")
            
            # Populate form fields
            js_code = <<-JS
              document.getElementById('cabinetName').value = '#{cabinet_name_escaped}';
              document.getElementById('width').value = #{width_mm};
              document.getElementById('depth').value = #{depth_mm};
              document.getElementById('height').value = #{height_mm};
              document.getElementById('panelThickness').value = #{panel_thickness_mm};
              document.getElementById('backThickness').value = #{back_thickness_mm};
              document.getElementById('backInset').value = #{back_inset_mm};
              document.getElementById('panelOverlap').value = '#{panel_overlap}';
              var enableSupportPanels = #{support_panel_count_int > 0 ? 'true' : 'false'};
              document.getElementById('enableSupportPanels').checked = enableSupportPanels;
              document.getElementById('supportPanelOptions').style.display = enableSupportPanels ? 'block' : 'none';
              document.getElementById('supportPanelCount').value = #{support_panel_count_int > 0 ? support_panel_count_int : 2};
              document.getElementById('supportPanelHeight').value = #{support_panel_height_mm};
              document.getElementById('supportPanelOrientation').value = '#{support_panel_orientation}';
              document.getElementById('quantity').value = 1;
              document.getElementById('quantity').disabled = true;
              document.getElementById('createButton').textContent = 'Update Selected Cabinet';
              document.getElementById('createButton').style.background = '#28a745';
              document.getElementById('cabinetInfo').style.display = 'block';
              document.getElementById('cabinetInfoText').textContent = 'Editing: #{cabinet_name_escaped}';
            JS
            
            dialog.execute_script(js_code)
          else
            # No cabinet selected - reset to create mode
            js_code = <<-JS
              document.getElementById('cabinetName').value = '';
              document.getElementById('quantity').value = 1;
              document.getElementById('quantity').disabled = false;
              document.getElementById('createButton').textContent = 'Create Cabinet';
              document.getElementById('createButton').style.background = '#007bff';
              document.getElementById('cabinetInfo').style.display = 'none';
            JS
            
            dialog.execute_script(js_code)
          end
        end
        
        # Callback to create cabinet
        dialog.add_action_callback('createCabinet') do |action_context, params|
          model = Sketchup.active_model
          selection = model.selection.first
          selected_cabinet = is_cabinet_group?(selection) ? selection : nil
          
          if selected_cabinet
            # Update existing cabinet
            update_cabinet_properties(selected_cabinet, params)
          else
            # Create new cabinet
            create_cabinet(params)
          end
        end
        
        # Callback to upload cabinets from Excel/CSV
        dialog.add_action_callback('uploadCabinetsFromFile') do |action_context, params|
          upload_cabinets_from_file
        end
        
        # Callback to show bulk upload dialog
        dialog.add_action_callback('showBulkUpload') do |action_context, params|
          show_bulk_cabinet_upload_dialog
        end
        
        dialog.show
        
        # Load cabinet properties after dialog is shown
        dialog.execute_script("if (window.sketchup) { window.sketchup.getSelectedCabinetProperties(); }")
      end
      
      # Show Bulk Cabinet Upload Dialog
      def show_bulk_cabinet_upload_dialog
        dialog = get_or_create_dialog('bulk_cabinet_upload', 'Bulk Cabinet Upload', 900, 700)
        dialog.set_url(File.join(__dir__, 'ui', 'bulk_cabinet_upload.html'))
        
        # Callback to upload file and display
        dialog.add_action_callback('uploadCabinetsFileAndDisplay') do |action_context, params|
          upload_cabinets_file_and_display(dialog)
        end
        
        # Callback to create bulk cabinets
        dialog.add_action_callback('createBulkCabinets') do |action_context, rows_data|
          create_bulk_cabinets(rows_data)
        end
        
        # Callback to download template CSV
        dialog.add_action_callback('downloadCabinetTemplate') do |action_context, params|
          download_cabinet_template
        end
        
        dialog.show
      end
      
      # Upload cabinets file and display in table
      def upload_cabinets_file_and_display(dialog)
        file_path = UI.openpanel('Select CSV/Excel File', '', 'CSV Files|*.csv||')
        return unless file_path && File.exist?(file_path)
        
        begin
          # Read all rows first
          all_rows = CSV.read(file_path, encoding: 'UTF-8')
          return if all_rows.empty?
          
          # Detect if first row is headers or data
          first_row = all_rows[0]
          has_headers = false
          
          # Check if first row looks like headers (contains text keywords)
          header_keywords = ['name', 'width', 'height', 'quantity', 'thickness']
          first_row_lower = first_row.map { |cell| cell.to_s.strip.downcase }
          has_headers = header_keywords.any? { |keyword| first_row_lower.any? { |cell| cell.include?(keyword) } }
          
          # If has headers, use first row as headers, otherwise use column positions
          if has_headers
            headers = first_row.map { |h| h.to_s.strip }
            data_rows = all_rows[1..-1] || []
            
            # Normalize headers for case-insensitive matching
            header_map = {}
            headers.each_with_index do |h, i|
              normalized = h.to_s.strip.downcase
              header_map[normalized] = i
            end
            
            cabinets_data = []
            data_rows.each do |row|
              next if row.nil? || row.empty?
              
              # Helper to get value by header name or position
              get_value = lambda do |possible_headers, default|
                possible_headers.each do |header|
                  normalized = header.to_s.strip.downcase
                  column_index = header_map[normalized]
                  if column_index && row[column_index]
                    value = row[column_index].to_s.strip
                    return value unless value.empty?
                  end
                end
                default
              end
              
              cabinets_data << {
                'name' => get_value.call(['name', 'cabinet name', 'cabinetname', 'cabinet'], ''),
                'width' => get_value.call(['width', 'w'], '600'),
                'depth' => get_value.call(['depth', 'd'], '580'),
                'height' => get_value.call(['height', 'h'], '720'),
                'quantity' => get_value.call(['quantity', 'qty', 'q'], '1'),
                'shelfQty' => get_value.call(['shelfqty', 'shelf qty', 'shelves', 'shelf count'], '0'),
                'partitionQty' => get_value.call(['partitionqty', 'partition qty', 'partitions', 'partition count'], '0'),
                'panelThickness' => get_value.call(['panelthickness', 'panel thickness', 'thickness', 't'], '18'),
                'backThickness' => get_value.call(['backthickness', 'back thickness'], '10'),
                'backInset' => get_value.call(['backinset', 'back inset'], '18')
              }
            end
          else
            # No headers - assume column order: Name, Width, Depth, Height, Quantity, ShelfQty, PartitionQty, PanelThickness, BackThickness, BackInset
            cabinets_data = []
            all_rows.each do |row|
              next if row.nil? || row.empty? || row[0].to_s.strip.empty?
              
              cabinets_data << {
                'name' => (row[0] || '').to_s.strip,
                'width' => (row[1] || '600').to_s.strip,
                'depth' => (row[2] || '580').to_s.strip,
                'height' => (row[3] || '720').to_s.strip,
                'quantity' => ((row[4] || '1').to_s.strip.to_i rescue 1).clamp(1, 100),
                'shelfQty' => ((row[5] || '0').to_s.strip.to_i rescue 0),
                'partitionQty' => ((row[6] || '0').to_s.strip.to_i rescue 0),
                'panelThickness' => (row[7] || '18').to_s.strip,
                'backThickness' => (row[8] || '10').to_s.strip,
                'backInset' => (row[9] || '18').to_s.strip
              }
            end
          end
          
          # Send data to dialog
          dialog.execute_script("window.displayCabinetsData(#{cabinets_data.to_json});")
        rescue => e
          UI.messagebox("Error reading file: #{e.message}\n\n#{e.backtrace.first}")
        end
      end
      
      # Create bulk cabinets from table data
      def create_bulk_cabinets(rows_data)
        return if rows_data.nil? || rows_data.empty?
        
        success_count = 0
        error_count = 0
        
        model = Sketchup.active_model
        model.start_operation('Bulk Create Cabinets', true)
        
        # Track names created in this batch to avoid duplicates
        created_names_in_batch = []
        
        rows_data.each_with_index do |row, index|
          begin
            # Ensure unique name for each cabinet in bulk upload
            original_name = row['name'] || ''
            unique_name = ensure_unique_cabinet_name(original_name)
            
            # Check if name conflicts with names already created in this batch
            if created_names_in_batch.include?(unique_name)
              unique_name = generate_random_name('Cabinet')
              # Keep generating until we get a unique name
              while created_names_in_batch.include?(unique_name)
                unique_name = generate_random_name('Cabinet')
              end
            end
            
            # Add to batch tracking
            created_names_in_batch << unique_name
            
            params = {
              'name' => unique_name,
              'quantity' => (row['quantity'] || 1).to_i,
              'shelfQty' => (row['shelfQty'] || 0).to_i,
              'partitionQty' => (row['partitionQty'] || 0).to_i,
              'width' => row['width'] || 600,
              'depth' => row['depth'] || 580,
              'height' => row['height'] || 720,
              'panelThickness' => row['panelThickness'] || 18,
              'backThickness' => row['backThickness'] || 10,
              'backInset' => row['backInset'] || 18
            }
            
            create_cabinet(params)
            success_count += 1
          rescue => e
            error_count += 1
            UI.messagebox("Error on row #{index + 1}: #{e.message}")
          end
        end
        
        model.commit_operation
        UI.messagebox("Bulk import complete!\nSuccess: #{success_count}\nErrors: #{error_count}")
      end
      
      # Show Cabinet Structure Dialog
      def show_cabinet_structure_dialog
        dialog = get_or_create_dialog('cabinet_structure', 'Cabinet Structure', 400, 350)
        dialog.set_url(File.join(__dir__, 'ui', 'cabinet_structure.html'))
        
        dialog.add_action_callback('updateStructure') do |action_context, params|
          update_cabinet_structure(params)
        end
        
        dialog.show
      end
      
      # Show Shelves & Partitions Dialog
      def show_shelves_partitions_dialog
        dialog = get_or_create_dialog('shelves_partitions', 'Shelves & Partitions', 400, 450)
        dialog.set_url(File.join(__dir__, 'ui', 'shelves_partitions.html'))
        
        dialog.add_action_callback('updateShelvesPartitions') do |action_context, params|
          update_shelves_partitions(params)
        end
        
        dialog.show
      end
      
      # Show Shutters/Doors Dialog
      def show_shutters_dialog
        dialog = get_or_create_dialog('shutters', 'Shutters / Doors', 400, 500)
        dialog.set_url(File.join(__dir__, 'ui', 'shutters.html'))
        
        dialog.add_action_callback('updateShutters') do |action_context, params|
          update_shutters(params)
        end
        
        dialog.show
      end
      
      
      # Show Property Panel for selected component
      def show_property_panel(component)
        dialog = get_or_create_dialog('property_panel', 'Component Properties', 350, 500)
        dialog.set_url(File.join(__dir__, 'ui', 'property_panel.html'))
        
        # Store component reference for updates
        @current_panel_component = component
        # Capture current selection for potential multi-apply (only component instances)
        begin
          model = Sketchup.active_model
          selection = model.selection.to_a
          @current_panel_components = selection.select { |e| e.is_a?(Sketchup::ComponentInstance) }
        rescue
          @current_panel_components = [component]
        end
        @suppress_update_messages = false
        # Enable auto-update when selection changes
        @update_property_panel_on_selection = true
        
        dialog.add_action_callback('updateProperty') do |action_context, params|
          if @current_panel_component
            # If user requested multi-apply of thickness only and multiple components are selected
            if params['applyToSelection'] && @current_panel_components && @current_panel_components.length > 1
              begin
                new_thickness_value = params['panelThickness']
                # Guard invalid thickness
                if !new_thickness_value || new_thickness_value.to_f <= 0.0
                  UI.messagebox("Please enter a valid thickness before applying to multiple panels.")
                else
                  @suppress_update_messages = true
                  @current_panel_components.each do |comp|
                    # Build per-component params using current dimensions from extract_component_data
                    data = extract_component_data(comp)
                    per_params = {
                      'width' => data[:width].to_f,
                      'height' => data[:height].to_f,
                      'panelThickness' => new_thickness_value.to_f
                    }
                    # Preserve adjust options if present/applicable
                    per_params['heightAdjust'] = data[:heightAdjust] if data[:heightAdjust]
                    per_params['widthAdjust'] = data[:widthAdjust] if data[:widthAdjust]
                    update_component_property(comp, per_params)
                  end
                end
              ensure
                @suppress_update_messages = false
              end
            else
              update_component_property(@current_panel_component, params)
            end
          end
        end
        
        # Add callback to get component data when dialog requests it
        dialog.add_action_callback('getComponentData') do |action_context|
          if @current_panel_component
            component_data = extract_component_data(@current_panel_component)
            # Augment with selection count for UI multi-apply affordance
            selection_count = (@current_panel_components && @current_panel_components.length) || 1
            component_data[:selectionCount] = selection_count
            dialog.execute_script("window.loadComponentData(#{component_data.to_json});")
          end
        end
        
        dialog.show
        
        # Extract component data and send it after dialog loads
        component_data = extract_component_data(component)
        
        # Convert to JSON for JavaScript
        json_data = component_data.to_json
        
        # Send data after dialog is ready - try multiple times
        dialog.execute_script("
          function sendData() {
            var data = #{json_data};
            console.log('Sending data:', data);
            if (typeof window.loadComponentData === 'function') {
              window.loadComponentData(data);
              console.log('Data sent successfully');
            } else {
              console.log('loadComponentData not ready, retrying...');
              setTimeout(sendData, 100);
            }
          }
          setTimeout(sendData, 300);
        ")
      end
      
      # Create cabinet with 5 core panels
      def create_cabinet(params)
        model = Sketchup.active_model
        
        quantity = (params['quantity'] || 1).to_i
        quantity = [quantity, 1].max  # Ensure at least 1
        quantity = [quantity, 100].min  # Limit to 100
        
        provided_name = params['name'].to_s.strip
        base_cabinet_name = nil
        
        # Determine base name for naming cabinets
        if provided_name.empty?
          # Auto-generate base name - will be set in loop
          base_cabinet_name = nil
        else
          # Use provided name as base
          base_cabinet_name = provided_name
        end

        model.start_operation("Create #{quantity} Cabinet(s)", true)
        cabinet_name = nil

        begin
          # Get cabinet parameters
          width = params['width'].to_f.mm
          depth = params['depth'].to_f.mm
          height = params['height'].to_f.mm
          panel_thickness = (params['panelThickness'] || 18).to_f.mm
          back_thickness = (params['backThickness'] || 10).to_f.mm
          back_inset = (params['backInset'] || 18).to_f.mm
          panel_overlap = (params['panelOverlap'] || 'none')
          support_panel_count = (params['supportPanelCount'] || 0).to_i
          support_panel_height = (params['supportPanelHeight'] || 100).to_f.mm
          support_panel_orientation = (params['supportPanelOrientation'] || 'vertical').to_s

          # Optional shelves and partitions from bulk upload / params
          shelf_qty = (params['shelfQty'] || 0).to_i
          partition_qty = (params['partitionQty'] || 0).to_i
          shelf_qty = [shelf_qty, 0].max
          partition_qty = [partition_qty, 0].max
          
          gap = 200.mm
          start_position = calculate_next_position
          current_x = start_position[0]
          
          # Initialize cabinet_number for auto-generated names
          cabinet_number = nil
          # Track names created in this batch to avoid duplicates within the same operation
          created_names_in_batch = []
          
          quantity.times do |index|
            # Generate unique name for each cabinet
            if provided_name.empty?
              # Auto-generated names
              if index == 0
                # First cabinet: get next number
                cabinet_number = get_next_cabinet_number
                cabinet_name = "C#{cabinet_number}"
                # Update counter to track this number
                @cabinet_counter = [@cabinet_counter, cabinet_number].max
              else
                # Subsequent cabinets: increment from previous number
                # Keep incrementing until we find an available number
                loop do
                  cabinet_number = cabinet_number + 1
                  # Check if this number is already used (from existing cabinets)
                  used_numbers = current_cabinet_numbers
                  break unless used_numbers.include?(cabinet_number)
                end
                cabinet_name = "C#{cabinet_number}"
                # Update counter to track this number
                @cabinet_counter = [@cabinet_counter, cabinet_number].max
              end
            else
              # User-provided names
              if quantity > 1
                # Multiple cabinets: use base_name + quantity suffix
                proposed_name = "#{base_cabinet_name}_#{index + 1}"
                
                # Ensure unique name - check both existing names and names in current batch
                if cabinet_name_taken?(proposed_name) || created_names_in_batch.include?(proposed_name)
                  cabinet_name = generate_random_name('Cabinet')
                  # Keep generating until we get a unique name (not in existing or current batch)
                  while created_names_in_batch.include?(cabinet_name)
                    cabinet_name = generate_random_name('Cabinet')
                  end
                else
                  cabinet_name = proposed_name
                end
              else
                # Single cabinet - ensure unique name
                cabinet_name = ensure_unique_cabinet_name(base_cabinet_name)
                # Check if it conflicts with names in current batch
                if created_names_in_batch.include?(cabinet_name)
                  cabinet_name = generate_random_name('Cabinet')
                  while created_names_in_batch.include?(cabinet_name)
                    cabinet_name = generate_random_name('Cabinet')
                  end
                end
              end
            end
            
            # Add to batch tracking
            created_names_in_batch << cabinet_name
            
            # Create cabinet group
            cabinet_group = model.active_entities.add_group
            cabinet_group.name = "#{cabinet_name} Cabinet"
            
            # Store cabinet attributes
            cabinet_group.set_attribute('DCC', 'is_cabinet', true)
            cabinet_group.set_attribute('DCC', 'cabinet_name', cabinet_name)
            cabinet_group.set_attribute('DCC', 'width', width)
            cabinet_group.set_attribute('DCC', 'depth', depth)
            cabinet_group.set_attribute('DCC', 'height', height)
            cabinet_group.set_attribute('DCC', 'panel_thickness', panel_thickness)
            cabinet_group.set_attribute('DCC', 'back_thickness', back_thickness)
            cabinet_group.set_attribute('DCC', 'back_inset', back_inset)
            cabinet_group.set_attribute('DCC', 'panel_overlap', panel_overlap)
            cabinet_group.set_attribute('DCC', 'support_panel_count', support_panel_count)
            cabinet_group.set_attribute('DCC', 'support_panel_height', support_panel_height)
            cabinet_group.set_attribute('DCC', 'support_panel_orientation', support_panel_orientation)
            cabinet_group.set_attribute('DCC', 'cabinet_number', cabinet_number) if cabinet_number
            
            # Calculate position (align next to existing cabinets)
            position = [current_x, 0, 0]
            cabinet_group.transformation = Geom::Transformation.new(position)
            
            # Create the 5 core panels
            create_left_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
            create_right_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
            create_bottom_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
            create_top_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
            create_back_panel(cabinet_group, cabinet_name, width, depth, height, back_thickness, back_inset)
            
            # Create support panels (pattas) if specified
            if support_panel_count > 0
              create_support_panels(cabinet_group, cabinet_name, width, depth, height, panel_thickness, support_panel_count, support_panel_height)
            end

            # Create shelves if requested
            if shelf_qty > 0
              add_shelves(cabinet_group, shelf_qty, panel_thickness)
            end

            # Create vertical partitions if requested
            if partition_qty > 0
              add_partitions(cabinet_group, partition_qty, panel_thickness)
            end
            
            # Do NOT create dimensions or name labels by default; they can be
            # added later via 'Show All DCC Dimensions & Names' from the
            # Extensions menu. This keeps the model clean unless user chooses
            # to show sizes and names.
            
            # Move to next position for next cabinet
            current_x = current_x + width + gap
          end
          
          model.commit_operation
          
          if quantity > 1
            UI.messagebox("#{quantity} cabinets created successfully!")
          else
            UI.messagebox("Cabinet '#{cabinet_name}' created successfully!")
          end
        rescue => e
          model.abort_operation
          UI.messagebox("Error creating cabinet(s): #{e.message}")
        end
      end
      
      # Create Left Panel
      def create_left_panel(cabinet_group, cabinet_name, width, depth, height, thickness, panel_overlap = 'none')
        # Calculate panel height and Z position based on overlap setting
        panel_height = height
        panel_z = 0  # Default: starts at bottom
        
        if panel_overlap == 'top'
          # Top out: left/right height = height - top thickness, starts at z=0
          panel_height = height - thickness
          panel_z = 0
        elsif panel_overlap == 'bottom'
          # Bottom out: left/right height = height - bottom thickness, starts on top of bottom panel
          panel_height = height - thickness
          panel_z = thickness  # Start above bottom panel
        elsif panel_overlap == 'left'
          # Left out: left panel height = full height, starts at z=0
          panel_height = height
          panel_z = 0
        elsif panel_overlap == 'right'
          # Right out: left panel height = height - (top + bottom thickness), between top and bottom
          panel_height = height - (2 * thickness)
          panel_z = thickness  # Starts above bottom panel
        end
        
        panel_def = create_panel_component("#{cabinet_name} - LEFT", thickness, depth, panel_height)
        instance = cabinet_group.entities.add_instance(panel_def, [0, 0, panel_z])
        instance.set_attribute('DCC', 'panel_type', 'left')
      end
      
      # Create Right Panel
      def create_right_panel(cabinet_group, cabinet_name, width, depth, height, thickness, panel_overlap = 'none')
        # Calculate panel height and Z position based on overlap setting
        panel_height = height
        panel_z = 0  # Default: starts at bottom
        
        if panel_overlap == 'top'
          # Top out: left/right height = height - top thickness, starts at z=0
          panel_height = height - thickness
          panel_z = 0
        elsif panel_overlap == 'bottom'
          # Bottom out: left/right height = height - bottom thickness, starts on top of bottom panel
          panel_height = height - thickness
          panel_z = thickness  # Start above bottom panel
        elsif panel_overlap == 'left'
          # Left out: right panel height = height - (top + bottom thickness), between top and bottom
          panel_height = height - (2 * thickness)
          panel_z = thickness  # Starts above bottom panel
        elsif panel_overlap == 'right'
          # Right out: right panel height = full height, starts at z=0
          panel_height = height
          panel_z = 0
        end
        
        panel_def = create_panel_component("#{cabinet_name} - RIGHT", thickness, depth, panel_height)
        instance = cabinet_group.entities.add_instance(panel_def, [width - thickness, 0, panel_z])
        instance.set_attribute('DCC', 'panel_type', 'right')
      end
      
      # Create Bottom Panel
      def create_bottom_panel(cabinet_group, cabinet_name, width, depth, height, thickness, panel_overlap = 'none')
        # Calculate panel width based on overlap setting
        panel_width = width - (2 * thickness)  # Standard: inner width
        panel_x = thickness  # Standard: inset by left panel thickness
        
        if panel_overlap == 'top'
          # Top out: bottom width = width - (left + right thickness)
          panel_width = width - (2 * thickness)
          panel_x = thickness
        elsif panel_overlap == 'bottom'
          # Bottom out: bottom width = full width
          panel_width = width
          panel_x = 0
        elsif panel_overlap == 'left'
          # Left out: bottom width = width - left thickness
          panel_width = width - thickness
          panel_x = thickness
        elsif panel_overlap == 'right'
          # Right out: bottom width = width - right thickness
          panel_width = width - thickness
          panel_x = 0
        end
        
        panel_def = create_panel_component("#{cabinet_name} - BOTTOM", panel_width, depth, thickness)
        instance = cabinet_group.entities.add_instance(panel_def, [panel_x, 0, 0])
        instance.set_attribute('DCC', 'panel_type', 'bottom')
      end
      
      # Create Top Panel
      def create_top_panel(cabinet_group, cabinet_name, width, depth, height, thickness, panel_overlap = 'none')
        # Calculate panel width and Z position based on overlap setting
        panel_width = width - (2 * thickness)  # Standard: inner width
        panel_x = thickness  # Standard: inset by left panel thickness
        panel_z = height - thickness  # Standard: at top
        
        if panel_overlap == 'top'
          # Top out: top width = full width
          panel_width = width
          panel_x = 0
          panel_z = height - thickness
        elsif panel_overlap == 'bottom'
          # Bottom out: top width = width - (left + right thickness)
          panel_width = width - (2 * thickness)
          panel_x = thickness
          panel_z = height - thickness
        elsif panel_overlap == 'left'
          # Left out: top width = width - left thickness
          panel_width = width - thickness
          panel_x = thickness
          panel_z = height - thickness
        elsif panel_overlap == 'right'
          # Right out: top width = width - right thickness
          panel_width = width - thickness
          panel_x = 0
          panel_z = height - thickness
        end
        
        panel_def = create_panel_component("#{cabinet_name} - TOP", panel_width, depth, thickness)
        instance = cabinet_group.entities.add_instance(panel_def, [panel_x, 0, panel_z])
        instance.set_attribute('DCC', 'panel_type', 'top')
      end
      
      # Create Back Panel
      def create_back_panel(cabinet_group, cabinet_name, width, depth, height, thickness, inset)
        # Back panel size: Cabinet Width - 18mm and Cabinet Height - 18mm
        back_width = width - 18.mm
        back_height = height - 18.mm
        panel_def = create_panel_component("#{cabinet_name} - BACK", back_width, back_height, thickness)
        
        # Position back panel: Back Inset means distance FROM THE BACK of cabinet
        # Back Inset = how much space AFTER the back panel to the back of the cabinet
        # Position the panel at: depth - inset
        # Center the panel (9mm from each side since it's 18mm smaller)
        x_position = 9.mm
        z_position = 9.mm
        y_position = depth - inset  # Position at depth - inset
        
        # Rotate 90 degrees around X axis and position
        transformation = Geom::Transformation.rotation([0, 0, 0], [1, 0, 0], 90.degrees)
        transformation = Geom::Transformation.translation([x_position, y_position, z_position]) * transformation
        
        instance = cabinet_group.entities.add_instance(panel_def, transformation)
        instance.set_attribute('DCC', 'panel_type', 'back')
      end
      
      # Create Support Panels (Pattas) for Hanging Cabinet
      # Orientation is read from cabinet_group attribute 'support_panel_orientation'
      # - 'horizontal': original behavior - horizontal strips stacked vertically
      # - 'vertical': new behavior - vertical strips spaced across cabinet width
      def create_support_panels(cabinet_group, cabinet_name, width, depth, height, panel_thickness, count, panel_height)
        return if count.to_i <= 0

        orientation = cabinet_group.get_attribute('DCC', 'support_panel_orientation') || 'vertical'
        orientation = orientation.to_s.downcase

        # Width available between left and right side panels
        support_width = width - (2 * panel_thickness)

        if orientation == 'horizontal'
          # Horizontal pattas: long across width, short in height, stacked vertically
          total_panel_height = count * panel_height
          available_gap_height = height - total_panel_height
          gap_between_panels = (count > 1) ? (available_gap_height / (count + 1)) : (available_gap_height / 2)
          start_z = gap_between_panels

          count.times do |index|
            panel_name = "#{cabinet_name} - SUPPORT PATT #{index + 1}"

            # width (x) spans almost full cabinet width, depth (y) is thickness, height (z) is user height
            panel_def = create_panel_component(panel_name, support_width, panel_thickness, panel_height)

            x_position = panel_thickness
            y_position = depth - panel_thickness
            z_position = start_z + (index * (panel_height + gap_between_panels))

            transformation = Geom::Transformation.translation([x_position, y_position, z_position])
            instance = cabinet_group.entities.add_instance(panel_def, transformation)
            instance.set_attribute('DCC', 'panel_type', 'support_patta')
            instance.set_attribute('DCC', 'support_patta_index', index + 1)
          end
        else
          # Vertical pattas: tall narrow strips running from near bottom to near top, spaced across width
          # Use panel_height as the strip width along X; ensure it is positive and not wider than support_width
          strip_width = [panel_height, support_width].min
          strip_width = panel_thickness if strip_width <= 0

          total_strip_width = count * strip_width
          available_gap_width = support_width - total_strip_width
          gap_between_strips = (count > 1) ? (available_gap_width / (count + 1)) : (available_gap_width / 2)
          gap_between_strips = 0 if gap_between_strips < 0

          # Vertical extent: match inner height used for vertical partitions
          vertical_height = height - (2 * panel_thickness)
          vertical_height = panel_thickness if vertical_height <= 0

          # Same vertical placement strategy as partitions: place instances
          # at z = panel_thickness so they sit fully between bottom and top.
          start_x = panel_thickness + gap_between_strips

          count.times do |index|
            panel_name = "#{cabinet_name} - SUPPORT PATT #{index + 1}"

            # width (x) is strip_width, depth (y) is thickness, height (z) is tall vertical span
            panel_def = create_panel_component(panel_name, strip_width, panel_thickness, vertical_height)

            x_position = start_x + (index * (strip_width + gap_between_strips))
            y_position = depth - panel_thickness
            z_position = panel_thickness

            transformation = Geom::Transformation.translation([x_position, y_position, z_position])
            instance = cabinet_group.entities.add_instance(panel_def, transformation)
            instance.set_attribute('DCC', 'panel_type', 'support_patta')
            instance.set_attribute('DCC', 'support_patta_index', index + 1)
          end
        end
      end
      
      # Create a panel component definition
      def create_panel_component(name, width, depth, height)
        definitions = Sketchup.active_model.definitions
        
        # Check if definition already exists
        existing_def = definitions[name]
        if existing_def
          existing_def.entities.clear!
          panel_def = existing_def
        else
          panel_def = definitions.add(name)
        end
        
        # Create panel geometry
        face = panel_def.entities.add_face([0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0])
        face.pushpull(-height)
        
        # Store panel attributes
        panel_def.set_attribute('DCC', 'is_panel', true)
        panel_def.set_attribute('DCC', 'width', width)
        panel_def.set_attribute('DCC', 'depth', depth)
        panel_def.set_attribute('DCC', 'height', height)
        
        panel_def
      end
      
      # Create back panel grooves in side panels
      def create_back_grooves(cabinet_group, cabinet_name, width, depth, height, panel_thickness, back_thickness, back_inset)
        groove_width = back_thickness
        groove_depth = 9.mm
        groove_height = height - 18.mm  # Same as back panel height
        panel_front_face = depth - back_inset - back_thickness
        groove_position_y = [[panel_front_face, 0.mm].max, depth - groove_depth].min
        
        # Create groove in LEFT panel
        left_groove_def = create_groove_component("#{cabinet_name} - LEFT GROOVE", groove_width, groove_depth, groove_height)
        # Position: on the inner face of left panel, at back_inset distance
        left_groove = cabinet_group.entities.add_instance(left_groove_def, [panel_thickness - groove_depth, groove_position_y, 9.mm])
        left_groove.set_attribute('DCC', 'panel_type', 'groove')
        
        # Create groove in RIGHT panel
        right_groove_def = create_groove_component("#{cabinet_name} - RIGHT GROOVE", groove_width, groove_depth, groove_height)
        # Position: on the inner face of right panel, at back_inset distance
        right_groove = cabinet_group.entities.add_instance(right_groove_def, [width - panel_thickness, groove_position_y, 9.mm])
        right_groove.set_attribute('DCC', 'panel_type', 'groove')
      end
      
      # Create groove component (cut-out)
      def create_groove_component(name, width, depth, height)
        definitions = Sketchup.active_model.definitions
        
        # Check if definition already exists
        existing_def = definitions[name]
        if existing_def
          existing_def.entities.clear!
          groove_def = existing_def
        else
          groove_def = definitions.add(name)
        end
        
        # Create groove geometry (a rectangular cut)
        face = groove_def.entities.add_face([0, 0, 0], [width, 0, 0], [width, 0, height], [0, 0, height])
        face.pushpull(depth)
        
        # Store groove attributes
        groove_def.set_attribute('DCC', 'is_groove', true)
        groove_def.set_attribute('DCC', 'width', width)
        groove_def.set_attribute('DCC', 'depth', depth)
        groove_def.set_attribute('DCC', 'height', height)
        
        groove_def
      end
      
      # Remove existing component instances matching panel types
      def remove_panel_instances(cabinet_group, panel_types)
        types = Array(panel_types)
        cabinet_group.entities.to_a.each do |entity|
          unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
            next
          end

          panel_type = entity.get_attribute('DCC', 'panel_type')
          entity.erase! if panel_type && types.include?(panel_type)
        end
      end
      
      # Parse a string of length values (mm) into SketchUp length units
      def parse_length_list(value)
        return [] unless value
        value.to_s.split(/[,;\n]+/).map { |entry| entry.strip }.reject(&:empty?).map do |entry|
          entry.to_f.mm
        end
      end
      
      # Get rightmost position of all DCC entities (cabinets and panels)
      # Returns the rightmost X coordinate of all existing entities
      def get_rightmost_dcc_position
        model = Sketchup.active_model
        max_x = 0.mm
        
        # Check all entities in model
        model.active_entities.each do |entity|
          right_edge = nil
          
          # Check if it's a cabinet (Group)
          if entity.is_a?(Sketchup::Group) && entity.get_attribute('DCC', 'is_cabinet')
            width = entity.get_attribute('DCC', 'width') || 0.mm
            transformation = entity.transformation
            origin_x = transformation.origin.x
            right_edge = origin_x + width
          # Check if it's a standalone panel (ComponentInstance)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'is_standalone_panel')
              width = entity.get_attribute('DCC', 'width') || 0.mm
              transformation = entity.transformation
              origin_x = transformation.origin.x
              right_edge = origin_x + width
            end
          end
          
          if right_edge && right_edge > max_x
            max_x = right_edge
          end
        end
        
        # Return rightmost X position (without gap)
        max_x
      end
      
      # Check if any cabinets or panels are overlapping
      def check_overlaps
        model = Sketchup.active_model
        entities = []
        overlaps = []
        
        # Collect all DCC entities with their positions and widths
        model.active_entities.each do |entity|
          name = nil
          left_x = nil
          right_x = nil
          width = nil
          
          # Check if it's a cabinet (Group)
          if entity.is_a?(Sketchup::Group) && entity.get_attribute('DCC', 'is_cabinet')
            name = entity.get_attribute('DCC', 'cabinet_name') || entity.name
            width = entity.get_attribute('DCC', 'width') || 0.mm
            transformation = entity.transformation
            left_x = transformation.origin.x
            right_x = left_x + width
          # Check if it's a standalone panel (ComponentInstance)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'is_standalone_panel')
              name = entity.get_attribute('DCC', 'name') || entity.name
              width = entity.get_attribute('DCC', 'width') || 0.mm
              transformation = entity.transformation
              left_x = transformation.origin.x
              right_x = left_x + width
            end
          end
          
          if left_x && right_x && name
            entities << {
              name: name,
              left_x: left_x,
              right_x: right_x,
              entity: entity
            }
          end
        end
        
        # Check for overlaps between entities
        entities.each_with_index do |entity1, i|
          entities[(i+1)..-1].each do |entity2|
            # Check if ranges overlap
            if (entity1[:left_x] < entity2[:right_x] && entity1[:right_x] > entity2[:left_x])
              overlaps << {
                entity1: entity1[:name],
                entity2: entity2[:name],
                overlap_start: [entity1[:left_x], entity2[:left_x]].max,
                overlap_end: [entity1[:right_x], entity2[:right_x]].min
              }
            end
          end
        end
        
        overlaps
      end
      
      # Calculate next position for new cabinet (right side of axis, positive X)
      def calculate_next_position
        gap = 200.mm  # Gap between cabinets
        
        # Only check cabinets for positioning (cabinets go right, panels go left)
        model = Sketchup.active_model
        max_x = 0.mm
        
        # Find rightmost cabinet
        model.active_entities.each do |entity|
          if entity.is_a?(Sketchup::Group) && entity.get_attribute('DCC', 'is_cabinet')
            width = entity.get_attribute('DCC', 'width') || 0.mm
            transformation = entity.transformation
            origin_x = transformation.origin.x
            right_edge = origin_x + width
            
            if right_edge > max_x
              max_x = right_edge
            end
          end
        end
        
        if max_x == 0.mm  # No existing cabinets, start at origin
          return [0, 0, 0]
        else
          # Place new cabinet after rightmost cabinet with gap
          return [max_x + gap, 0, 0]
        end
      end
      
      # Update cabinet structure
      def update_cabinet_structure(params)
        model = Sketchup.active_model
        selection = model.selection.first
        
        unless selection && selection.get_attribute('DCC', 'is_cabinet')
          UI.messagebox("Please select a cabinet first!")
          return
        end
        
        model.start_operation('Update Cabinet Structure', true)
        
        # Update attributes and rebuild
        panel_thickness = params['panelThickness'].to_f.mm
        back_thickness = params['backThickness'].to_f.mm
        back_inset = params['backInset'].to_f.mm
        
        selection.set_attribute('DCC', 'panel_thickness', panel_thickness)
        selection.set_attribute('DCC', 'back_thickness', back_thickness)
        selection.set_attribute('DCC', 'back_inset', back_inset)
        
        rebuild_cabinet(selection)
        
        model.commit_operation
      end
      
      # Update shelves and partitions
      def update_shelves_partitions(params)
        model = Sketchup.active_model
        selection = model.selection.first
        
        unless selection && selection.get_attribute('DCC', 'is_cabinet')
          UI.messagebox("Please select a cabinet first!")
          return
        end
        
        model.start_operation('Update Shelves, Partitions & Drawers', true)
        
        # Remove existing shelves and partitions (but not drawer partitions)
        selection.entities.to_a.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            panel_type = entity.get_attribute('DCC', 'panel_type')
            if panel_type == 'shelf' || panel_type == 'partition'
              entity.erase!
            end
          end
        end
        
        # Add new shelves
        num_shelves = params['numShelves'].to_i
        if num_shelves > 0
          add_shelves(selection, num_shelves, params['shelfThickness'].to_f.mm)
        end
        
        # Add new partitions
        num_partitions = params['numPartitions'].to_i
        if num_partitions > 0
          add_partitions(selection, num_partitions, params['partitionThickness'].to_f.mm)
        end
        
        # Add drawer partitions (these are additive, not replacing existing ones)
        num_drawer_partitions = params['numDrawerPartitions'].to_i
        if num_drawer_partitions > 0
          drawer_partition_thickness = params['drawerPartitionThickness'].to_f.mm
          insert_drawer_partitions(selection, num_drawer_partitions, drawer_partition_thickness)
        end
        
        # Add drawers to full cabinet (if no drawer partitions exist)
        num_drawers = params['numDrawers'].to_i
        if num_drawers > 0
          drawer_height = params['drawerHeight'].to_f.mm
          drawer_front_thickness = params['drawerFrontThickness'].to_f.mm
          
          # Check if drawer partitions exist
          drawer_partitions = get_drawer_partitions(selection)
          if drawer_partitions.empty?
            # No partitions - add drawers to full cabinet
            add_drawers_to_full_cabinet(selection, num_drawers, drawer_height, drawer_front_thickness)
          else
            # Partitions exist - show message to use section selection
            UI.messagebox("Drawer partitions detected. Please use 'Select Section' from Cabinet Actions menu to add drawers to specific sections.")
          end
        end
        
        model.commit_operation
      end
      
      # Add drawers to full cabinet (when no partitions exist)
      def add_drawers_to_full_cabinet(cabinet_group, num_drawers, drawer_height, drawer_front_thickness)
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        # Full cabinet dimensions
        drawer_width = width - (2 * panel_thickness)
        drawer_depth = depth - back_inset - back_thickness - 20.mm # Leave some clearance
        inner_height = height - (2 * panel_thickness)
        
        # Validate dimensions
        if drawer_width <= 0 || drawer_depth <= 0
          UI.messagebox("Cabinet dimensions are invalid. Cannot add drawer.")
          return
        end
        
        # Check if drawers fit
        total_drawer_height = num_drawers * drawer_height
        if total_drawer_height > inner_height
          UI.messagebox("Drawers do not fit in cabinet. Total height #{total_drawer_height.to_mm}mm exceeds available #{inner_height.to_mm}mm.")
          return
        end
        
        # Get existing drawers in full cabinet
        existing_drawers = get_full_cabinet_drawers(cabinet_group)
        existing_count = existing_drawers.length
        
        # Calculate starting Z position (stack on top of existing drawers)
        bottom_z = panel_thickness
        if existing_drawers.any?
          # Find the highest existing drawer by checking bounding box
          max_z = existing_drawers.map do |drawer|
            drawer_transformation = drawer.transformation
            bbox = drawer.bounds
            max_point = bbox.max.transform(drawer_transformation)
            max_point.z
          end.max
          bottom_z = [max_z, panel_thickness].max
        end
        
        # Calculate spacing
        spacing = drawer_height
        
        # Add drawers
        (1..num_drawers).each do |i|
          drawer_index = existing_count + i
          drawer_z = bottom_z + ((i - 1) * spacing)
          
          # Check if drawer would exceed cabinet height
          if drawer_z + drawer_height > height - panel_thickness
            UI.messagebox("Warning: Drawer #{i} would exceed cabinet height. Only #{i - 1} drawer(s) added.")
            break
          end
          
          # Create drawer group
          drawer_group = cabinet_group.entities.add_group
          drawer_group.name = "#{cabinet_name} - DRAWER #{drawer_index}"
          drawer_group.set_attribute('DCC', 'is_drawer', true)
          drawer_group.set_attribute('DCC', 'section_index', -1) # -1 means full cabinet
          drawer_group.set_attribute('DCC', 'section_name', 'Full Cabinet')
          drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
          
          # Position drawer group
          drawer_group.transformation = Geom::Transformation.translation([panel_thickness, 0, drawer_z])
          
          # Create drawer components using helper method
          create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
        end
      end
      
      # Get drawers for full cabinet (no section)
      def get_full_cabinet_drawers(cabinet_group)
        drawers = []
        cabinet_group.entities.each do |entity|
          if entity.is_a?(Sketchup::Group)
            if entity.get_attribute('DCC', 'is_drawer')
              section_index = entity.get_attribute('DCC', 'section_index')
              if section_index == -1 || section_index.nil? # Full cabinet drawers
                drawers << entity
              end
            end
          end
        end
        drawers
      end
      
      # Add shelves to cabinet
      def add_shelves(cabinet_group, num_shelves, shelf_thickness)
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        
        shelf_width = width - (2 * panel_thickness)
        shelf_depth = depth - back_inset - back_thickness
        inner_height = height - (2 * panel_thickness)
        
        spacing = inner_height / (num_shelves + 1)
        
        (1..num_shelves).each do |i|
          shelf_z = panel_thickness + (i * spacing)
          cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
          shelf_def = create_panel_component("#{cabinet_name} - SHELF #{i}", shelf_width, shelf_depth, shelf_thickness)
          instance = cabinet_group.entities.add_instance(shelf_def, [panel_thickness, 0, shelf_z])
          instance.set_attribute('DCC', 'panel_type', 'shelf')
        end
      end
      
      # Add vertical partitions to cabinet
      def add_partitions(cabinet_group, num_partitions, partition_thickness)
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        
        partition_depth = depth - back_inset - back_thickness
        partition_height = height - (2 * panel_thickness)
        inner_width = width - (2 * panel_thickness)
        
        spacing = inner_width / (num_partitions + 1)
        
        (1..num_partitions).each do |i|
          partition_x = panel_thickness + (i * spacing)
          cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
          partition_def = create_panel_component("#{cabinet_name} - PARTITION #{i}", partition_thickness, partition_depth, partition_height)
          instance = cabinet_group.entities.add_instance(partition_def, [partition_x, 0, panel_thickness])
          instance.set_attribute('DCC', 'panel_type', 'partition')
        end
      end
      
      # Update shutters/doors
      def update_shutters(params)
        model = Sketchup.active_model
        cabinet_group = model.selection.first
        unless cabinet_group && cabinet_group.get_attribute('DCC', 'is_cabinet')
          UI.messagebox("Please select a cabinet first!")
          return
        end

        model.start_operation('Update Shutters', true)

        remove_panel_instances(cabinet_group, ['shutter'])

        door_type = (params['doorType'] || 'none').downcase
        door_thickness = (params['doorThickness'] || 18).to_f.mm

        cabinet_group.set_attribute('DCC', 'door_type', door_type)
        cabinet_group.set_attribute('DCC', 'door_thickness', door_thickness)

        if door_type == 'none' || door_thickness <= 0
          model.commit_operation
          return
        end

        width = cabinet_group.get_attribute('DCC', 'width')
        height = cabinet_group.get_attribute('DCC', 'height')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')

        gap = 2.mm
        case door_type
        when 'single'
          shutter_def = create_panel_component("#{cabinet_name} - SHUTTER", width, door_thickness, height)
          transformation = Geom::Transformation.translation([0, -door_thickness, 0])
          instance = cabinet_group.entities.add_instance(shutter_def, transformation)
          instance.set_attribute('DCC', 'panel_type', 'shutter')
          instance.set_attribute('DCC', 'shutter_style', 'single')
        when 'double'
          shutter_width = (width - gap) / 2.0
          if shutter_width <= 0
            UI.messagebox('Cabinet is too narrow for double shutters.')
            model.abort_operation
            return
          end

          left_def = create_panel_component("#{cabinet_name} - SHUTTER LEFT", shutter_width, door_thickness, height)
          right_def = create_panel_component("#{cabinet_name} - SHUTTER RIGHT", shutter_width, door_thickness, height)

          left_transformation = Geom::Transformation.translation([0, -door_thickness, 0])
          right_transformation = Geom::Transformation.translation([shutter_width + gap, -door_thickness, 0])

          left_instance = cabinet_group.entities.add_instance(left_def, left_transformation)
          left_instance.set_attribute('DCC', 'panel_type', 'shutter')
          left_instance.set_attribute('DCC', 'shutter_style', 'double_left')

          right_instance = cabinet_group.entities.add_instance(right_def, right_transformation)
          right_instance.set_attribute('DCC', 'panel_type', 'shutter')
          right_instance.set_attribute('DCC', 'shutter_style', 'double_right')
        else
          UI.messagebox("Unsupported shutter type: #{door_type}")
          model.abort_operation
          return
        end

        model.commit_operation
      end
      
      # Upload cabinets from Excel/CSV file
      def upload_cabinets_from_file
        file_path = UI.openpanel('Select CSV/Excel File', '', 'CSV Files|*.csv||')
        return unless file_path && File.exist?(file_path)
        
        begin
          rows = CSV.read(file_path, headers: true, encoding: 'UTF-8')
          original_headers = rows.headers
          
          # Normalize headers for case-insensitive matching
          header_map = {}
          original_headers.each do |h|
            normalized = h.to_s.strip.downcase
            header_map[normalized] = h
          end
          
          success_count = 0
          error_count = 0
          
          model = Sketchup.active_model
          model.start_operation('Bulk Create Cabinets', true)
          
          rows.each_with_index do |row, index|
            begin
              # Helper to get value by various header name possibilities
              get_value = lambda do |possible_headers, default|
                possible_headers.each do |header|
                  normalized = header.to_s.strip.downcase
                  original_header = header_map[normalized]
                  if original_header && row[original_header]
                    value = row[original_header].to_s.strip
                    return value unless value.empty?
                  end
                end
                default
              end
              
              # Map headers to parameters - try various header name variations
              params = {
                'name' => get_value.call(['name', 'cabinet name', 'cabinetname', 'cabinet'], ''),
                'width' => get_value.call(['width', 'w'], '600').to_f,
                'depth' => get_value.call(['depth', 'd'], '580').to_f,
                'height' => get_value.call(['height', 'h'], '720').to_f,
                'quantity' => get_value.call(['quantity', 'qty', 'q'], '1').to_i,
                'panelThickness' => get_value.call(['panelthickness', 'panel thickness', 'panelthickness', 'thickness', 't'], '18').to_f,
                'backThickness' => get_value.call(['backthickness', 'back thickness', 'backthickness'], '10').to_f,
                'backInset' => get_value.call(['backinset', 'back inset', 'backinset'], '18').to_f
              }
              
              # Debug: show what values we're getting (can remove later)
              # UI.messagebox("Row #{index + 2}: #{params.inspect}")
              
              create_cabinet(params)
              success_count += 1
            rescue => e
              error_count += 1
              UI.messagebox("Error on row #{index + 2}: #{e.message}\n\n#{e.backtrace.first}")
            end
          end
          
          model.commit_operation
          UI.messagebox("Bulk import complete!\nSuccess: #{success_count}\nErrors: #{error_count}")
        rescue => e
          UI.messagebox("Error reading file: #{e.message}")
        end
      end
      
      # Show Panel Creation Dialog
      def show_panel_creation_dialog
        dialog = get_or_create_dialog('panel_creation', 'Panel Creation', 450, 500)
        dialog.set_url(File.join(__dir__, 'ui', 'panel_creation.html'))
        
        # Callback to create panel
        dialog.add_action_callback('createPanel') do |action_context, params|
          create_standalone_panel(params)
        end
        
        # Callback to upload panels from Excel/CSV
        dialog.add_action_callback('uploadPanelsFromFile') do |action_context, params|
          upload_panels_from_file
        end
        
        # Callback to show bulk upload dialog
        dialog.add_action_callback('showBulkUpload') do |action_context, params|
          show_bulk_panel_upload_dialog
        end
        
        dialog.show
      end
      
      # Show Bulk Panel Upload Dialog
      def show_bulk_panel_upload_dialog
        dialog = get_or_create_dialog('bulk_panel_upload', 'Bulk Panel Upload', 700, 600)
        dialog.set_url(File.join(__dir__, 'ui', 'bulk_panel_upload.html'))
        
        # Callback to upload file and display
        dialog.add_action_callback('uploadPanelsFileAndDisplay') do |action_context, params|
          upload_panels_file_and_display(dialog)
        end
        
        # Callback to create bulk panels
        dialog.add_action_callback('createBulkPanels') do |action_context, rows_data|
          create_bulk_panels(rows_data)
        end
        
        # Callback to download template CSV
        dialog.add_action_callback('downloadPanelTemplate') do |action_context, params|
          download_panel_template
        end
        
        dialog.show
      end
      
      # Upload panels file and display in table
      def upload_panels_file_and_display(dialog)
        file_path = UI.openpanel('Select CSV/Excel File', '', 'CSV Files|*.csv||')
        return unless file_path && File.exist?(file_path)
        
        begin
          # Read all rows first
          all_rows = CSV.read(file_path, encoding: 'UTF-8')
          return if all_rows.empty?
          
          # Detect if first row is headers or data
          first_row = all_rows[0]
          has_headers = false
          
          # Check if first row looks like headers (contains text keywords)
          header_keywords = ['name', 'width', 'height', 'quantity', 'thickness']
          first_row_lower = first_row.map { |cell| cell.to_s.strip.downcase }
          has_headers = header_keywords.any? { |keyword| first_row_lower.any? { |cell| cell.include?(keyword) } }
          
          # If has headers, use first row as headers, otherwise use column positions
          if has_headers
            headers = first_row.map { |h| h.to_s.strip }
            data_rows = all_rows[1..-1] || []
            
            # Normalize headers for case-insensitive matching
            header_map = {}
            headers.each_with_index do |h, i|
              normalized = h.to_s.strip.downcase
              header_map[normalized] = i
            end
            
            panels_data = []
            data_rows.each_with_index do |row, index|
              next if row.nil? || row.empty?
              
              # Helper to get value by header name or position
              get_value = lambda do |possible_headers, default|
                possible_headers.each do |header|
                  normalized = header.to_s.strip.downcase
                  column_index = header_map[normalized]
                  if column_index && row[column_index]
                    value = row[column_index].to_s.strip
                    return value unless value.empty?
                  end
                end
                default
              end
              
            panels_data << {
              'name' => get_value.call(['name', 'panel name', 'panelname', 'panel'], "Panel #{index + 1}"),
              'quantity' => (get_value.call(['quantity', 'qty', 'q'], '1').to_i rescue 1).clamp(1, 100),
              'width' => get_value.call(['width', 'w'], '600'),
              'height' => get_value.call(['height', 'h'], '720'),
              'thickness' => get_value.call(['thickness', 't'], '18')
            }
            end
          else
            # No headers - assume column order: Name, Width, Height, Quantity, Thickness
            panels_data = []
            all_rows.each_with_index do |row, index|
              next if row.nil? || row.empty? || row[0].to_s.strip.empty?
              
              panels_data << {
                'name' => (row[0] || "Panel #{index + 1}").to_s.strip,
                'quantity' => ((row[3] || '1').to_s.strip.to_i rescue 1).clamp(1, 100),
                'width' => (row[1] || '600').to_s.strip,
                'height' => (row[2] || '720').to_s.strip,
                'thickness' => (row[4] || '18').to_s.strip
              }
            end
          end
          
          # Send data to dialog
          dialog.execute_script("window.displayPanelsData(#{panels_data.to_json});")
        rescue => e
          UI.messagebox("Error reading file: #{e.message}\n\n#{e.backtrace.first}")
        end
      end
      
      # Create bulk panels from table data
      def create_bulk_panels(rows_data)
        return if rows_data.nil? || rows_data.empty?
        
        success_count = 0
        error_count = 0
        gap = 200.mm  # Gap between panels
        
        model = Sketchup.active_model
        model.start_operation('Bulk Create Panels', true)
        
        # Calculate starting position (left side, going negative)
        # Get leftmost position of EXISTING panels (before this bulk operation)
        leftmost = get_leftmost_panel_position
        
        # Track current position and created panels in this batch
        current_x = nil
        created_names_in_batch = []
        created_panels_in_batch = []  # Track panels created in this batch for position tracking
        
        rows_data.each_with_index do |row, index|
          begin
            # Ensure unique name for each panel in bulk upload
            original_name = row['name'] || "Panel #{index + 1}"
            unique_name = ensure_unique_panel_name(original_name)
            # If name was empty and returned nil, generate random
            unique_name = generate_random_name('Panel') if unique_name.nil?
            
            # Check if name conflicts with names already created in this batch
            if created_names_in_batch.include?(unique_name)
              unique_name = generate_random_name('Panel')
              # Keep generating until we get a unique name
              while created_names_in_batch.include?(unique_name)
                unique_name = generate_random_name('Panel')
              end
            end
            
            # Add to batch tracking (will be updated by create_standalone_panel if quantity > 1)
            created_names_in_batch << unique_name
            
            params = {
              'name' => unique_name,
              'quantity' => row['quantity'] || 1,
              'width' => row['width'] || 600,
              'height' => row['height'] || 720,
              'thickness' => row['thickness'] || 18
            }
            
            # Calculate position for this panel (first panel of this row)
            panel_width = (params['width'] || 600).to_f.mm
            quantity = (params['quantity'] || 1).to_i
            
            # Calculate starting position for this row's panels
            if current_x.nil?
              # First panel of first row
              if leftmost == 0.mm
                # No existing panels, start from origin going left
                # Position so right edge of first panel is at origin
                current_x = -panel_width
              else
                # Start to the left of leftmost EXISTING panel
                current_x = leftmost - panel_width - gap
              end
            else
              # Subsequent rows: position to the left of the leftmost panel created in this batch
              # Calculate the leftmost position of panels created so far in this batch
              batch_leftmost = leftmost
              created_panels_in_batch.each do |panel|
                panel_x = panel.transformation.origin.x
                batch_leftmost = [batch_leftmost, panel_x].min
              end
              
              # Position new row to the left of the leftmost panel from this batch with 200mm gap
              current_x = batch_leftmost - panel_width - gap
            end
            
            # Store the starting position before creating panels
            row_start_x = current_x
            
            # Create panel(s) at calculated position (skip commit for batch operation)
            # create_standalone_panel will handle quantity and positioning sequentially
            create_standalone_panel(params, current_x, true)
            
            # After create_standalone_panel creates panels, find the leftmost panel created
            # to calculate the position for the next row
            row_leftmost = row_start_x  # Start with the starting position
            
            # Find all panels created in this iteration (by matching name pattern)
            model.active_entities.each do |entity|
              if entity.is_a?(Sketchup::ComponentInstance)
                if entity.get_attribute('DCC', 'is_standalone_panel')
                  panel_name = entity.get_attribute('DCC', 'name')
                  if panel_name && (panel_name == unique_name || panel_name.start_with?("#{unique_name}_"))
                    # Check if this panel is newly created (not in our batch yet)
                    unless created_panels_in_batch.include?(entity)
                      created_panels_in_batch << entity
                      # Get panel's left edge position (origin.x is the left edge)
                      panel_x = entity.transformation.origin.x
                      # Update row_leftmost to track the leftmost panel in this row
                      row_leftmost = [row_leftmost, panel_x].min
                    end
                  end
                end
              end
            end
            
            # Update current_x to the leftmost edge of panels created in this row
            # This will be used as reference for the next row
            # The next row will be positioned at: row_leftmost - next_panel_width - gap
            current_x = row_leftmost
            
            success_count += 1
          rescue => e
            error_count += 1
            UI.messagebox("Error on row #{index + 1}: #{e.message}")
          end
        end
        
        model.commit_operation
        UI.messagebox("Bulk import complete!\nSuccess: #{success_count}\nErrors: #{error_count}")
      end
      
      # Get leftmost position of all DCC panels (for left side positioning)
      def get_leftmost_panel_position
        model = Sketchup.active_model
        min_x = 0.mm
        
        # Check all entities in model for standalone panels
        model.active_entities.each do |entity|
          left_edge = nil
          
          # Check if it's a standalone panel (ComponentInstance)
          if entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'is_standalone_panel')
              width = entity.get_attribute('DCC', 'width') || 0.mm
              transformation = entity.transformation
              origin_x = transformation.origin.x
              left_edge = origin_x  # Left edge is the origin (panels positioned from left)
            end
          end
          
          if left_edge && left_edge < min_x
            min_x = left_edge
          end
        end
        
        # Return leftmost X position (most negative)
        min_x
      end
      
      # Get next panel position (side by side, on left side of axis going negative)
      def get_next_panel_position
        gap = 200.mm  # Gap between panels
        
        # Get leftmost panel position (most negative)
        leftmost = get_leftmost_panel_position
        
        if leftmost == 0.mm  # No existing panels
          # Start from origin, go left by panel width + gap
          return 0.mm
        else
          # Place new panel to the left of leftmost panel with gap
          # leftmost is negative, so we subtract (panel width + gap) to go further left
          # But we don't know panel width here, so we'll calculate it in create function
          return leftmost - gap  # Will be adjusted by panel width in create function
        end
      end
      
      # Rearrange all standalone panels with 200mm gap between them
      # Panels are arranged from right to left (negative X direction) starting from origin
      def rearrange_all_standalone_panels
        model = Sketchup.active_model
        gap = 200.mm
        
        # Collect all standalone panels
        panels = []
        model.active_entities.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'is_standalone_panel')
              panels << entity
            end
          end
        end
        
        # Skip if no panels found
        return if panels.empty?
        
        # First, remove all dimensions from all panels before rearranging
        # This prevents old dimensions from staying at old positions
        panels.each do |panel|
          remove_panel_dimensions(panel)
        end
        
        # Sort panels by name first (p1, p2, p3, etc.) for consistent ordering
        # If name-based sorting fails, fall back to position-based sorting
        begin
          panels.sort_by! do |panel|
            name = panel.get_attribute('DCC', 'name') || ''
            # Extract number from name (e.g., "p3" -> 3)
            if name =~ /^p(\d+)$/i
              # Panels with numeric names (p1, p2, etc.) sorted by number
              $1.to_i
            else
              # Panels without numeric names go to the end, sorted by position
              # Use large number to ensure they come after numbered panels
              transformation = panel.transformation
              999999 + transformation.origin.x
            end
          end
        rescue => e
          # If sorting by name fails, use position-based sorting
          puts "Warning: Could not sort panels by name: #{e.message}"
          panels.sort_by! do |panel|
            transformation = panel.transformation
            transformation.origin.x
          end
          panels.reverse!  # Reverse so rightmost (highest X) comes first
        end
        
        # Calculate new positions starting from origin going left
        current_x = 0.mm
        
        panels.each do |panel|
          width = panel.get_attribute('DCC', 'width') || 0.mm
          height = panel.get_attribute('DCC', 'height') || 0.mm
          thickness = panel.get_attribute('DCC', 'thickness') || 0.mm
          
          # Position panel so its right edge is at current_x, then move left
          # Left edge will be at current_x - width
          new_x = current_x - width
          
          # Get current Y and Z to preserve them
          current_transformation = panel.transformation
          current_y = current_transformation.origin.y
          current_z = current_transformation.origin.z
          
          # Create new transformation with updated X position
          new_transformation = Geom::Transformation.translation([new_x, current_y, current_z])
          panel.transformation = new_transformation
          
          # Add dimensions back after panel is repositioned
          add_panel_dimensions(panel, width, height, thickness)
          
          # Update current_x for next panel (move left by panel width + gap)
          current_x = new_x - gap
        end
      end
      
      # Get next available panel number (p1, p2, p3, etc.)
      def get_next_panel_number
        model = Sketchup.active_model
        used_numbers = []
        
        # Check all entities in model for standalone panels
        model.active_entities.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'is_standalone_panel')
              panel_name = entity.get_attribute('DCC', 'name') || entity.name
              # Check if name matches pattern "p" followed by a number (e.g., "p1", "p2", "p10")
              if panel_name.to_s =~ /^p(\d+)$/i
                used_numbers << $1.to_i
              end
            end
          end
        end
        
        # Find next available number
        if used_numbers.empty?
          return 1
        else
          max_number = used_numbers.max
          return max_number + 1
        end
      end
      
      # Create standalone panel (not part of cabinet)
      def create_standalone_panel(params, position_x = nil, skip_commit = false)
        model = Sketchup.active_model
        
        quantity = (params['quantity'] || 1).to_i
        quantity = [quantity, 1].max  # Ensure at least 1
        quantity = [quantity, 100].min  # Limit to 100
        
        # If no name provided, generate sequential name (p1, p2, p3, etc.)
        use_auto_naming = params['name'].nil? || params['name'].to_s.strip.empty?
        
        if use_auto_naming
          start_number = get_next_panel_number
        else
          base_name = params['name'].to_s.strip
        end
        
        width = params['width'].to_f.mm
        height = params['height'].to_f.mm
        thickness = params['thickness'].to_f.mm
        
        if width <= 0 || height <= 0 || thickness <= 0
          UI.messagebox("All dimensions must be greater than zero.")
          return
        end
        
        # Start operation only if not in a batch operation
        unless skip_commit
          model.start_operation("Create #{quantity} Panel(s)", true)
        end
        
        # Calculate starting position: if not provided, use auto-positioning
        if position_x.nil?
          # Get leftmost panel position
          leftmost = get_leftmost_panel_position
          gap = 200.mm
          
          if leftmost == 0.mm
            # No existing panels, start from origin going left
            # Position so right edge is at origin (panel extends to the left)
            current_x = -width  # Position at negative width so right edge is at 0
          else
            # Position to the left of leftmost panel
            # leftmost is the left edge of leftmost panel, place new panel to its left
            current_x = leftmost - width - gap  # Left edge of new panel
          end
        else
          current_x = position_x
        end
        
        gap = 200.mm
        # Track names created in this batch to avoid duplicates within the same operation
        created_names_in_batch = []
        
        quantity.times do |index|
          # Generate unique name for each panel
          if use_auto_naming
            # Auto-naming: use sequential numbers (p1, p2, p3, etc.)
            proposed_name = "p#{start_number + index}"
            # Ensure unique name - check both existing names and names in current batch
            if panel_name_taken?(proposed_name) || created_names_in_batch.include?(proposed_name)
              panel_name = generate_random_name('Panel')
              # Keep generating until we get a unique name (not in existing or current batch)
              while created_names_in_batch.include?(panel_name)
                panel_name = generate_random_name('Panel')
              end
            else
              panel_name = proposed_name
            end
          elsif quantity > 1
            # User provided name with multiple panels: use base_name + quantity suffix
            proposed_name = "#{base_name}_#{index + 1}"
            # Ensure unique name - check both existing names and names in current batch
            if panel_name_taken?(proposed_name) || created_names_in_batch.include?(proposed_name)
              panel_name = generate_random_name('Panel')
              # Keep generating until we get a unique name (not in existing or current batch)
              while created_names_in_batch.include?(panel_name)
                panel_name = generate_random_name('Panel')
              end
            else
              panel_name = proposed_name
            end
          else
            # Single panel with user-provided name - ensure unique
            panel_name = ensure_unique_panel_name(base_name)
            # If name was empty and returned nil, use auto-naming
            if panel_name.nil?
              proposed_name = "p#{start_number + index}"
              if panel_name_taken?(proposed_name)
                panel_name = generate_random_name('Panel')
              else
                panel_name = proposed_name
              end
            end
            # Check if it conflicts with names in current batch
            if created_names_in_batch.include?(panel_name)
              panel_name = generate_random_name('Panel')
              while created_names_in_batch.include?(panel_name)
                panel_name = generate_random_name('Panel')
              end
            end
          end
          
          # Add to batch tracking
          created_names_in_batch << panel_name
          
          # For standalone panel: width (x), thickness (y depth), height (z)
          # Position at (current_x, 0, 0) - bottom-left corner
          # For left side: current_x will be negative
          panel_def = create_panel_component(panel_name, width, thickness, height)
          transformation = Geom::Transformation.translation([current_x, 0, 0])
          instance = model.active_entities.add_instance(panel_def, transformation)
          
          instance.set_attribute('DCC', 'panel_type', 'standalone')
          instance.set_attribute('DCC', 'is_standalone_panel', true)
          instance.set_attribute('DCC', 'name', panel_name)
          instance.set_attribute('DCC', 'width', width)
          instance.set_attribute('DCC', 'height', height)
          instance.set_attribute('DCC', 'thickness', thickness)
          
          # Do NOT create dimensions for panels by default; they can be added via
          # 'Show All DCC Dimensions & Names' when needed.
          
          # Move to next position for next panel (going further left)
          current_x = current_x - width - gap
        end
        
        unless skip_commit
          model.commit_operation
          if quantity > 1
            UI.messagebox("#{quantity} panels created successfully!")
          else
            panel_display_name = use_auto_naming ? "p#{start_number}" : base_name
            UI.messagebox("Panel '#{panel_display_name}' created successfully!")
          end
        end
      end
      
      # Add dimensions to a panel instance to show its size
      # Uses actual edge start and end points from the panel geometry
      def add_panel_dimensions(instance, width, height, thickness)
        model = Sketchup.active_model
        entities = model.active_entities
        
        # Get the transformation and definition of the instance
        transformation = instance.transformation
        definition = instance.definition
        
        # Get all edges from the panel definition
        def_edges = definition.entities.grep(Sketchup::Edge)
        
        # Find edges by their direction vectors and position
        # Panel is created with: width (x), thickness (y), height (z)
        # Face is at z=0, pushed down by -height, so bottom is at z=-height
        # Top face is at z=0 (visible from top view)
        
        width_edge = nil      # Top front edge (at z=0, y=0) - for width measurement
        height_edge = nil     # Left front edge (at x=0, y=0) - for height measurement
        thickness_edge = nil  # Top right edge (at z=0, x=width) - for thickness measurement on right side
        
        tolerance = 0.01  # Tolerance for coordinate comparison (in model units)
        
        def_edges.each do |edge|
          start_pt = edge.start.position
          end_pt = edge.end.position
          
          # Calculate edge vector
          edge_vector = end_pt - start_pt
          edge_length = edge_vector.length
          
          # Skip zero-length edges
          next if edge_length < 0.001
          
          # Normalize the vector to get direction
          edge_dir = edge_vector.normalize
          
          # Width edge: Top front edge - parallel to X-axis, at z=0 (top face), y=0 (front)
          # This is the edge on the top face that goes from left to right
          if (edge_dir.x.abs - 1.0).abs < 0.1 && 
             edge_dir.y.abs < 0.1 && 
             edge_dir.z.abs < 0.1 &&
             (edge_length - width).abs < 0.1.mm &&
             start_pt.z.abs < tolerance && end_pt.z.abs < tolerance &&
             start_pt.y.abs < tolerance && end_pt.y.abs < tolerance
            width_edge = edge
          end
          
          # Height edge: Left front edge - parallel to Z-axis, at x=0 (left), y=0 (front)
          # This is the vertical edge on the left front corner
          if edge_dir.x.abs < 0.1 && 
             edge_dir.y.abs < 0.1 && 
             (edge_dir.z.abs - 1.0).abs < 0.1 &&
             (edge_length - height).abs < 0.1.mm &&
             start_pt.x.abs < tolerance && end_pt.x.abs < tolerance &&
             start_pt.y.abs < tolerance && end_pt.y.abs < tolerance
            height_edge = edge
          end
          
          # Thickness edge: Top right edge - parallel to Y-axis, at z=0 (top), x=width (right)
          # This is the edge on the top face at the right side that goes from front to back
          if edge_dir.x.abs < 0.1 && 
             (edge_dir.y.abs - 1.0).abs < 0.1 && 
             edge_dir.z.abs < 0.1 &&
             (edge_length - thickness).abs < 0.1.mm &&
             start_pt.z.abs < tolerance && end_pt.z.abs < tolerance &&
             (start_pt.x - width).abs < tolerance && (end_pt.x - width).abs < tolerance
            thickness_edge = edge
          end
        end
        
        # Offset distance for dimension placement (outside the panel)
        offset_distance = 50.mm
        
        dimension_ids = []
        
        begin
          # Width dimension: left end to right end (top front edge)
          # Position above the top edge as shown in reference image
          if width_edge
            left_point = width_edge.start.position
            right_point = width_edge.end.position
            
            # Ensure left point has smaller x coordinate
            if left_point.x > right_point.x
              left_point, right_point = right_point, left_point
            end
            
            # Transform to world coordinates
            left_point_world = left_point.transform(transformation)
            right_point_world = right_point.transform(transformation)
            
            # Offset vector points upward (positive Z direction) to position above the top edge
            width_offset_vector = Geom::Vector3d.new(0, 0, offset_distance)
            
            # Create dimension using edge endpoints
            dimension1 = entities.add_dimension_linear(
              left_point_world,
              right_point_world,
              width_offset_vector
            )
            dimension_ids << dimension1.entityID if dimension1
          end
          
          # Height dimension: bottom end to top end (left front edge)
          # Position to the left of the left edge as shown in reference image
          if height_edge
            bottom_point = height_edge.start.position
            top_point = height_edge.end.position
            
            # Ensure bottom point has smaller z coordinate
            if bottom_point.z > top_point.z
              bottom_point, top_point = top_point, bottom_point
            end
            
            # Transform to world coordinates
            bottom_point_world = bottom_point.transform(transformation)
            top_point_world = top_point.transform(transformation)
            
            # Offset vector points left (negative X direction) to position to the left of the panel
            height_offset_vector = Geom::Vector3d.new(-offset_distance, 0, 0)
            
            # Create dimension using edge endpoints
            dimension2 = entities.add_dimension_linear(
              bottom_point_world,
              top_point_world,
              height_offset_vector
            )
            dimension_ids << dimension2.entityID if dimension2
          end
          
          # Thickness dimension: front end to back end (left side, upper corner toward center)
          # Position in the upper left area, but closer to the center of the panel
          # Use points on left front and left back edges at upper portion (closer to top)
          # Position it between the corner and center, in the upper left quadrant
          upper_height = -height * 0.2  # Position at about 20% down from top (upper portion)
          left_front_upper = Geom::Point3d.new(0, 0, upper_height)  # Upper-left-front point
          left_back_upper = Geom::Point3d.new(0, thickness, upper_height)  # Upper-left-back point
          
          # Transform to world coordinates
          left_front_upper_world = left_front_upper.transform(transformation)
          left_back_upper_world = left_back_upper.transform(transformation)
          
          # Offset vector: positioned left but not too far (toward center), and in upper area
          # Less negative X (closer to center), higher Z (upper portion)
          thickness_offset_vector = Geom::Vector3d.new(-offset_distance * 1.2, 0, offset_distance * 0.5)
          
          # Create dimension - displayed in upper left, toward center
          dimension3 = entities.add_dimension_linear(
            left_front_upper_world,
            left_back_upper_world,
            thickness_offset_vector
          )
          dimension_ids << dimension3.entityID if dimension3
          
          # Fallback: If edges not found, create dimensions using calculated points
          unless width_edge && height_edge && thickness_edge
            # Calculate corner points in local coordinates
            # Top face is at z=0, bottom is at z=-height
            top_left_front = Geom::Point3d.new(0, 0, 0)
            top_right_front = Geom::Point3d.new(width, 0, 0)
            top_right_back = Geom::Point3d.new(width, thickness, 0)
            bottom_left_front = Geom::Point3d.new(0, 0, -height)
            
            # Transform to world coordinates
            top_left_front_world = top_left_front.transform(transformation)
            top_right_front_world = top_right_front.transform(transformation)
            top_right_back_world = top_right_back.transform(transformation)
            bottom_left_front_world = bottom_left_front.transform(transformation)
            
            # Create width dimension if not found
            unless width_edge
              width_offset_vector = Geom::Vector3d.new(0, 0, offset_distance)
              dimension1 = entities.add_dimension_linear(
                top_left_front_world,
                top_right_front_world,
                width_offset_vector
              )
              dimension_ids << dimension1.entityID if dimension1
            end
            
            # Create height dimension if not found
            unless height_edge
              height_offset_vector = Geom::Vector3d.new(-offset_distance, 0, 0)
              dimension2 = entities.add_dimension_linear(
                bottom_left_front_world,
                top_left_front_world,
                height_offset_vector
              )
              dimension_ids << dimension2.entityID if dimension2
            end
            
            # Create thickness dimension if not found - on left side, upper corner toward center
            # Use points on left front and left back edges at upper portion (closer to top)
            upper_height = -height * 0.2  # Position at about 20% down from top (upper portion)
            left_front_upper = Geom::Point3d.new(0, 0, upper_height)  # Upper-left-front point
            left_back_upper = Geom::Point3d.new(0, thickness, upper_height)  # Upper-left-back point
            
            left_front_upper_world = left_front_upper.transform(transformation)
            left_back_upper_world = left_back_upper.transform(transformation)
            
            # Offset vector: positioned left but not too far (toward center), and in upper area
            thickness_offset_vector = Geom::Vector3d.new(-offset_distance * 1.2, 0, offset_distance * 0.5)
            dimension3 = entities.add_dimension_linear(
              left_front_upper_world,
              left_back_upper_world,
              thickness_offset_vector
            )
            dimension_ids << dimension3.entityID if dimension3
          end
          
          # Store dimension IDs in panel instance attributes for later removal
          if dimension_ids.any?
            instance.set_attribute('DCC', 'dimension_ids', dimension_ids)
          end
          
          # Debug output
          if !width_edge || !height_edge || !thickness_edge
            puts "Debug: Used fallback dimension creation"
            puts "Edge detection - Width: #{width_edge ? 'found' : 'NOT FOUND'}, Height: #{height_edge ? 'found' : 'NOT FOUND'}, Thickness: #{thickness_edge ? 'found' : 'NOT FOUND'}"
          end
          
        rescue => e
          # If dimension creation fails, show error message for debugging
          error_msg = "Could not create dimensions: #{e.message}"
          puts error_msg
          puts e.backtrace.first(5).join("\n")
          UI.messagebox("Dimension Error: #{e.message}")
        end
      end
      
      # Remove old dimensions associated with a panel instance
      def remove_panel_dimensions(panel_instance)
        model = Sketchup.active_model
        entities = model.active_entities
        
        dimensions_to_remove = []
        
        # First, try to remove by stored dimension IDs (preferred method)
        dimension_ids = panel_instance.get_attribute('DCC', 'dimension_ids')
        if dimension_ids && dimension_ids.is_a?(Array) && dimension_ids.any?
          dimension_ids.each do |dim_id|
            begin
              entity = entities.find_by_id(dim_id)
              if entity && entity.is_a?(Sketchup::Dimension) && entity.valid?
                dimensions_to_remove << entity
              end
            rescue => e
              # Dimension may have already been deleted, continue
            end
          end
        end
        
        # Also check by position and instance path (in case IDs weren't stored or dimensions moved)
        # Get panel dimensions and position BEFORE geometry changes
        transformation = panel_instance.transformation
        panel_origin = transformation.origin
        
        # Get dimensions from definition attributes (these are the OLD dimensions before update)
        definition = panel_instance.definition
        def_width = definition.get_attribute('DCC', 'width') || 0.mm
        def_height = definition.get_attribute('DCC', 'height') || 0.mm
        def_depth = definition.get_attribute('DCC', 'depth') || 0.mm
        
        # For standalone panels, also check instance attributes
        width = panel_instance.get_attribute('DCC', 'width') || def_width
        height = panel_instance.get_attribute('DCC', 'height') || def_height
        thickness = panel_instance.get_attribute('DCC', 'thickness') || def_depth
        
        # Calculate panel corner points in world coordinates using OLD dimensions
        # Panel is created with: width (x), thickness (y), height (z)
        # Top face is at z=0, bottom is at z=-height
        corners = [
          Geom::Point3d.new(0, 0, 0).transform(transformation),           # top_left_front
          Geom::Point3d.new(width, 0, 0).transform(transformation),       # top_right_front
          Geom::Point3d.new(0, thickness, 0).transform(transformation),   # top_left_back
          Geom::Point3d.new(width, thickness, 0).transform(transformation), # top_right_back
          Geom::Point3d.new(0, 0, -height).transform(transformation),     # bottom_left_front
          Geom::Point3d.new(width, 0, -height).transform(transformation), # bottom_right_front
          Geom::Point3d.new(0, thickness, -height).transform(transformation), # bottom_left_back
          Geom::Point3d.new(width, thickness, -height).transform(transformation) # bottom_right_back
        ]
        
        # Create a wider bounding box around THIS panel to catch dimensions
        # Dimensions are placed 50mm away, so check within 150mm to be safe
        offset_distance = 50.mm
        max_offset = offset_distance * 3  # 150mm margin to catch all dimensions
        
        # Calculate bounding box limits
        min_x = panel_origin.x - max_offset
        max_x = panel_origin.x + width + max_offset
        min_y = panel_origin.y - max_offset
        max_y = panel_origin.y + thickness + max_offset
        min_z = panel_origin.z - height - max_offset
        max_z = panel_origin.z + max_offset
        
        # Use more lenient tolerance for corner matching (dimensions might be slightly off)
        tolerance = 5.mm  # More lenient tolerance to catch dimensions that are close
        
        # Check all dimensions in the model
        entities.grep(Sketchup::Dimension).each do |dimension|
          next if dimensions_to_remove.include?(dimension)  # Skip if already marked for removal
          next unless dimension.valid?  # Skip if dimension is invalid
          
          begin
            # Check if dimension is attached to this panel instance via InstancePath
            dim_start = dimension.start rescue nil
            dim_end = dimension.end rescue nil
            
            # First check: Is dimension attached to this panel instance?
            attached_to_panel = false
            if dim_start.is_a?(Array) && dim_start.length >= 2 && dim_start[0].is_a?(Sketchup::InstancePath)
              if dim_start[0].include?(panel_instance)
                attached_to_panel = true
              end
            end
            if !attached_to_panel && dim_end.is_a?(Array) && dim_end.length >= 2 && dim_end[0].is_a?(Sketchup::InstancePath)
              if dim_end[0].include?(panel_instance)
                attached_to_panel = true
              end
            end
            
            # If attached to panel, mark for removal immediately
            if attached_to_panel
              dimensions_to_remove << dimension
              next
            end
            
            # Second check: Position-based matching
            start_pt = nil
            end_pt = nil
            
            if dim_start
              # Extract point - could be Geom::Point3d or array with InstancePath
              if dim_start.is_a?(Array) && dim_start.length >= 2
                if dim_start[1].is_a?(Geom::Point3d)
                  start_pt = dim_start[1]
                end
              elsif dim_start.is_a?(Geom::Point3d)
                start_pt = dim_start
              end
            end
            
            if dim_end
              if dim_end.is_a?(Array) && dim_end.length >= 2
                if dim_end[1].is_a?(Geom::Point3d)
                  end_pt = dim_end[1]
                end
              elsif dim_end.is_a?(Geom::Point3d)
                end_pt = dim_end
              end
            end
            
            # Only proceed if we have valid points
            if start_pt && end_pt
              connects_to_this_panel = false
              
              # Calculate dimension vector to check direction
              dim_vector = end_pt - start_pt
              dim_length = dim_vector.length
              
              # Check if this is a thickness dimension (measures along Y-axis, front to back)
              # Thickness dimensions connect points with same X and Z, different Y
              is_thickness_dim = false
              if dim_length > 0
                dim_dir = dim_vector.normalize
                # Thickness dimension: primarily along Y-axis (front to back)
                # X and Z should be similar, Y should be different
                if dim_dir.y.abs > 0.7 && dim_dir.x.abs < 0.3 && dim_dir.z.abs < 0.3
                  # Check if both points are within panel bounds
                  x_similar = (start_pt.x - end_pt.x).abs < tolerance * 2
                  z_similar = (start_pt.z - end_pt.z).abs < tolerance * 2
                  if x_similar && z_similar
                    is_thickness_dim = true
                  end
                end
              end
              
              # Check if start and end points are near THIS panel's corners or edges
              start_near_corner = false
              end_near_corner = false
              
              corners.each do |corner|
                if start_pt.distance(corner) < tolerance
                  start_near_corner = true
                end
                if end_pt.distance(corner) < tolerance
                  end_near_corner = true
                end
              end
              
              # Check if points are near panel edges (for thickness dimensions)
              start_near_edge = false
              end_near_edge = false
              if is_thickness_dim
                # For thickness dimensions, check if points are on left edge (x near 0 or x near width)
                # and within Y and Z bounds of the panel
                start_on_left = (start_pt.x - panel_origin.x).abs < tolerance || (start_pt.x - (panel_origin.x + width)).abs < tolerance
                end_on_left = (end_pt.x - panel_origin.x).abs < tolerance || (end_pt.x - (panel_origin.x + width)).abs < tolerance
                
                if start_on_left && start_pt.y >= min_y && start_pt.y <= max_y && start_pt.z >= min_z && start_pt.z <= max_z
                  start_near_edge = true
                end
                if end_on_left && end_pt.y >= min_y && end_pt.y <= max_y && end_pt.z >= min_z && end_pt.z <= max_z
                  end_near_edge = true
                end
              end
              
              # Dimension must connect to at least one corner/edge of THIS panel
              if start_near_corner || end_near_corner || start_near_edge || end_near_edge
                # Additional check: ensure dimension is within bounding box of THIS panel
                start_in_box = (start_pt.x >= min_x && start_pt.x <= max_x &&
                               start_pt.y >= min_y && start_pt.y <= max_y &&
                               start_pt.z >= min_z && start_pt.z <= max_z)
                
                end_in_box = (end_pt.x >= min_x && end_pt.x <= max_x &&
                             end_pt.y >= min_y && end_pt.y <= max_y &&
                             end_pt.z >= min_z && end_pt.z <= max_z)
                
                # Dimension text should also be near this panel
                text_near_panel = false
                begin
                  dim_text_pos = dimension.text_position
                  if dim_text_pos
                    text_in_box = (dim_text_pos.x >= min_x && dim_text_pos.x <= max_x &&
                                  dim_text_pos.y >= min_y && dim_text_pos.y <= max_y &&
                                  dim_text_pos.z >= min_z && dim_text_pos.z <= max_z)
                    text_near_panel = text_in_box
                  end
                rescue => e
                  # text_position might not be available, skip this check
                end
                
                # More lenient check: remove if dimension connects to panel corners/edges OR is within bounding box
                if (start_near_corner || end_near_corner || start_near_edge || end_near_edge) && (start_in_box || end_in_box || text_near_panel)
                  connects_to_this_panel = true
                elsif start_in_box && end_in_box
                  # Both points are in the bounding box, likely belongs to this panel
                  connects_to_this_panel = true
                end
              end
              
              if connects_to_this_panel
                dimensions_to_remove << dimension
              end
            end
          rescue => e
            # Skip if dimension can't be processed
            puts "Error checking dimension: #{e.message}"
          end
        end
        
        # Remove all found dimensions
        removed_count = 0
        dimensions_to_remove.each do |dim|
          begin
            if dim.valid?
              dim.erase!
              removed_count += 1
            end
          rescue => e
            puts "Error removing dimension: #{e.message}"
          end
        end
        
        # Clear the stored dimension IDs
        panel_instance.delete_attribute('DCC', 'dimension_ids')
        
        # Debug output
        puts "Removed #{removed_count} old dimension(s) for panel"
      end
      
      # Remove old dimensions associated with a cabinet
      def remove_cabinet_dimensions(cabinet_group)
        model = Sketchup.active_model
        entities = model.active_entities
        
        dimensions_to_remove = []
        
        # First, try to remove by stored dimension IDs (preferred method)
        dimension_ids = cabinet_group.get_attribute('DCC', 'dimension_ids')
        if dimension_ids && dimension_ids.is_a?(Array) && dimension_ids.any?
          dimension_ids.each do |dim_id|
            begin
              entity = entities.find_by_id(dim_id)
              if entity && entity.is_a?(Sketchup::Dimension)
                dimensions_to_remove << entity
              end
            rescue => e
              # Dimension may have already been deleted, continue
            end
          end
        end
        
        # Always also check by position (in case IDs weren't stored or dimensions moved)
        # Get cabinet dimensions and position
        transformation = cabinet_group.transformation
        cabinet_origin = transformation.origin
        width = cabinet_group.get_attribute('DCC', 'width') || 0.mm
        height = cabinet_group.get_attribute('DCC', 'height') || 0.mm
        depth = cabinet_group.get_attribute('DCC', 'depth') || 0.mm
        
        # Calculate all cabinet corner points in world coordinates
        # These are the points that dimensions connect to
        corners = [
          Geom::Point3d.new(0, 0, height).transform(transformation),      # top_left_front
          Geom::Point3d.new(width, 0, height).transform(transformation),  # top_right_front
          Geom::Point3d.new(0, depth, height).transform(transformation),  # top_left_back
          Geom::Point3d.new(width, depth, height).transform(transformation), # top_right_back
          Geom::Point3d.new(0, 0, 0).transform(transformation),          # bottom_left_front
          Geom::Point3d.new(width, 0, 0).transform(transformation),      # bottom_right_front
          Geom::Point3d.new(0, depth, 0).transform(transformation),      # bottom_left_back
          Geom::Point3d.new(width, depth, 0).transform(transformation)   # bottom_right_back
        ]
        
        # Calculate bounding box around cabinet (with extra margin for dimensions)
        offset_distance = 50.mm  # Dimensions are placed 50mm away
        margin = offset_distance + 100.mm  # Extra margin for finding dimensions
        max_distance = Math.sqrt(width**2 + height**2 + depth**2) + margin
        
        tolerance = 50.mm  # Larger tolerance for finding dimensions
        
        # Check all dimensions in the model
        entities.grep(Sketchup::Dimension).each do |dimension|
          next if dimensions_to_remove.include?(dimension)  # Skip if already marked for removal
          
          begin
            # Try to get dimension start and end points
            dim_start = dimension.start rescue nil
            dim_end = dimension.end rescue nil
            dim_offset = dimension.offset rescue nil
            
            # Check if dimension connects to any cabinet corner
            start_pt = nil
            end_pt = nil
            
            if dim_start
              # Extract point - could be Geom::Point3d or array with InstancePath
              if dim_start.is_a?(Array) && dim_start.length >= 2
                start_pt = dim_start[1]  # Point is second element in array
              elsif dim_start.is_a?(Geom::Point3d)
                start_pt = dim_start
              end
            end
            
            if dim_end
              if dim_end.is_a?(Array) && dim_end.length >= 2
                end_pt = dim_end[1]  # Point is second element in array
              elsif dim_end.is_a?(Geom::Point3d)
                end_pt = dim_end
              end
            end
            
            # Check if dimension connects to cabinet corners
            if start_pt && end_pt
              connects_to_cabinet = false
              
              # Check if start or end point is near any cabinet corner
              corners.each do |corner|
                if start_pt.distance(corner) < tolerance || end_pt.distance(corner) < tolerance
                  connects_to_cabinet = true
                  break
                end
              end
              
              # Also check if dimension is within cabinet bounds (for extra safety)
              if !connects_to_cabinet
                # Check if dimension points are within cabinet bounding box
                start_dist = start_pt.distance(cabinet_origin)
                end_dist = end_pt.distance(cabinet_origin)
                
                # If both points are within reasonable distance of cabinet, it's likely a cabinet dimension
                if start_dist < max_distance && end_dist < max_distance
                  connects_to_cabinet = true
                end
              end
              
              # Additional check: if dimension text is near cabinet, also consider it
              if !connects_to_cabinet
                begin
                  dim_text_pos = dimension.text_position
                  if dim_text_pos && dim_text_pos.distance(cabinet_origin) < max_distance
                    connects_to_cabinet = true
                  end
                rescue => e
                  # text_position might not be available, skip
                end
              end
              
              if connects_to_cabinet
                dimensions_to_remove << dimension
              end
            end
          rescue => e
            # Skip if dimension can't be processed
            puts "Error checking dimension: #{e.message}"
          end
        end
        
        # Remove all found dimensions
        removed_count = 0
        dimensions_to_remove.each do |dim|
          begin
            dim.erase!
            removed_count += 1
          rescue => e
            puts "Error removing dimension: #{e.message}"
          end
        end
        
        # Clear the stored dimension IDs
        cabinet_group.delete_attribute('DCC', 'dimension_ids')
        
        # Debug output
        puts "Removed #{removed_count} old dimension(s) for cabinet"
      end
      
      # Add dimensions to a cabinet group to show its size (width, depth, height)
      # Based on reference image: width above top, depth on left side, height on right side
      def add_cabinet_dimensions(cabinet_group, width, depth, height)
        model = Sketchup.active_model
        entities = model.active_entities
        
        # Get the transformation of the cabinet group
        transformation = cabinet_group.transformation
        
        # Cabinet is positioned at [current_x, 0, 0] in the group's local coordinates
        # The cabinet group contains panels that define the cabinet bounds
        # Calculate corner points based on cabinet dimensions
        # Cabinet extends from:
        # - X: 0 to width
        # - Y: 0 to depth (front to back)
        # - Z: 0 to height (bottom to top)
        
        # Top front corners (z=height, y=0)
        top_left_front = Geom::Point3d.new(0, 0, height)
        top_right_front = Geom::Point3d.new(width, 0, height)
        
        # Top back corners (z=height, y=depth)
        top_left_back = Geom::Point3d.new(0, depth, height)
        
        # Bottom front corners (z=0, y=0)
        bottom_left_front = Geom::Point3d.new(0, 0, 0)
        bottom_right_front = Geom::Point3d.new(width, 0, 0)
        
        # Transform points to world coordinates
        top_left_front_world = top_left_front.transform(transformation)
        top_right_front_world = top_right_front.transform(transformation)
        top_left_back_world = top_left_back.transform(transformation)
        bottom_right_front_world = bottom_right_front.transform(transformation)
        
        # Offset distance for dimension placement (outside the cabinet)
        offset_distance = 50.mm
        
        dimension_ids = []
        
        begin
          # Width dimension: left end to right end (top front edge)
          # Position above the top edge as shown in reference image
          width_offset_vector = Geom::Vector3d.new(0, 0, offset_distance)
          dimension1 = entities.add_dimension_linear(
            top_left_front_world,
            top_right_front_world,
            width_offset_vector
          )
          dimension_ids << dimension1.entityID if dimension1
          
          # Depth dimension: front end to back end (top left edge)
          # Position on the left side as shown in reference image
          depth_offset_vector = Geom::Vector3d.new(-offset_distance, 0, 0)
          dimension2 = entities.add_dimension_linear(
            top_left_front_world,
            top_left_back_world,
            depth_offset_vector
          )
          dimension_ids << dimension2.entityID if dimension2
          
          # Height dimension: bottom end to top end (right front edge)
          # Position on the right side as shown in reference image
          height_offset_vector = Geom::Vector3d.new(offset_distance, 0, 0)
          dimension3 = entities.add_dimension_linear(
            bottom_right_front_world,
            top_right_front_world,
            height_offset_vector
          )
          dimension_ids << dimension3.entityID if dimension3
          
          # Store dimension IDs in cabinet attributes for later removal
          cabinet_group.set_attribute('DCC', 'dimension_ids', dimension_ids) if dimension_ids.any?
          
        rescue => e
          # If dimension creation fails, show error message for debugging
          error_msg = "Could not create cabinet dimensions: #{e.message}"
          puts error_msg
          puts e.backtrace.first(5).join("\n")
        end
      end
      
      # Add cabinet name label at the bottom of the cabinet
      def add_cabinet_name_label(cabinet_group, cabinet_name, width, depth, height)
        model = Sketchup.active_model
        entities = model.active_entities
        
        # Get the transformation of the cabinet group
        transformation = cabinet_group.transformation
        
        # Calculate the center bottom point of the cabinet (front edge, centered horizontally)
        # Position: center of width (width/2), front edge (y=0), bottom (z=0)
        center_bottom_point = Geom::Point3d.new(width / 2.0, 0, 0)
        
        # Transform to world coordinates
        center_bottom_world = center_bottom_point.transform(transformation)
        
        # Offset distance below the cabinet (below the bottom edge)
        offset_distance = 80.mm  # Position below the cabinet
        text_offset = Geom::Vector3d.new(0, 0, -offset_distance)
        text_position = center_bottom_world + text_offset
        
        begin
          # Create text entity with cabinet name
          text_entity = entities.add_text(cabinet_name, text_position)
          
          # Store text entity ID in cabinet attributes for later removal
          text_id = text_entity.entityID
          existing_text_ids = cabinet_group.get_attribute('DCC', 'name_label_ids') || []
          existing_text_ids << text_id
          cabinet_group.set_attribute('DCC', 'name_label_ids', existing_text_ids)
          
        rescue => e
          # If text creation fails, show error message for debugging
          error_msg = "Could not create cabinet name label: #{e.message}"
          puts error_msg
          puts e.backtrace.first(5).join("\n")
        end
      end
      
      # Remove cabinet name label
      def remove_cabinet_name_label(cabinet_group)
        model = Sketchup.active_model
        entities = model.active_entities
        
        labels_to_remove = []
        
        # First, try to remove by stored text IDs (preferred method)
        text_ids = cabinet_group.get_attribute('DCC', 'name_label_ids')
        if text_ids && text_ids.is_a?(Array) && text_ids.any?
          text_ids.each do |text_id|
            begin
              entity = entities.find_by_id(text_id)
              if entity && entity.is_a?(Sketchup::Text)
                labels_to_remove << entity
              end
            rescue => e
              # Text may have already been deleted, continue
            end
          end
        end
        
        # Also check by position (in case IDs weren't stored or text moved)
        transformation = cabinet_group.transformation
        cabinet_origin = transformation.origin
        width = cabinet_group.get_attribute('DCC', 'width') || 0.mm
        height = cabinet_group.get_attribute('DCC', 'height') || 0.mm
        depth = cabinet_group.get_attribute('DCC', 'depth') || 0.mm
        
        # Calculate expected text position (center bottom - offset)
        center_bottom_point = Geom::Point3d.new(width / 2.0, 0, 0)
        center_bottom_world = center_bottom_point.transform(transformation)
        offset_distance = 80.mm
        expected_text_position = center_bottom_world + Geom::Vector3d.new(0, 0, -offset_distance)
        
        tolerance = 100.mm  # Tolerance for finding text near expected position
        
        # Check all text entities in the model
        entities.grep(Sketchup::Text).each do |text_entity|
          next if labels_to_remove.include?(text_entity)  # Skip if already marked for removal
          
          begin
            text_point = text_entity.point
            if text_point && text_point.distance(expected_text_position) < tolerance
              labels_to_remove << text_entity
            end
          rescue => e
            # Skip if text can't be processed
          end
        end
        
        # Remove all found text labels
        removed_count = 0
        labels_to_remove.each do |text|
          begin
            text.erase!
            removed_count += 1
          rescue => e
            puts "Error removing text label: #{e.message}"
          end
        end
        
        # Clear the stored text IDs
        cabinet_group.delete_attribute('DCC', 'name_label_ids')
        
        # Debug output
        puts "Removed #{removed_count} old name label(s) for cabinet" if removed_count > 0
      end
      
      # Hide all DCC dimensions and cabinet name labels in the active model
      def hide_all_dcc_dimensions_and_labels
        model = Sketchup.active_model
        entities = model.active_entities
        
        model.start_operation('Hide DCC Dimensions & Names', true)
        begin
          # Hide cabinet dimensions and name labels
          entities.grep(Sketchup::Group).each do |group|
            next unless group.get_attribute('DCC', 'is_cabinet')
            remove_cabinet_dimensions(group)
            remove_cabinet_name_label(group)
          end
          
          # Hide dimensions for panels (standalone and panel-marked components)
          entities.grep(Sketchup::ComponentInstance).each do |instance|
            is_panel = instance.get_attribute('DCC', 'is_standalone_panel') ||
                       instance.definition.get_attribute('DCC', 'is_panel')
            next unless is_panel
            remove_panel_dimensions(instance)
          end
          
          model.commit_operation
        rescue => e
          model.abort_operation
          UI.messagebox("Error hiding DCC dimensions and names: #{e.message}")
        end
      end
      
      # Show (recreate) all DCC dimensions and cabinet name labels in the active model
      def show_all_dcc_dimensions_and_labels
        model = Sketchup.active_model
        entities = model.active_entities
        
        model.start_operation('Show DCC Dimensions & Names', true)
        begin
          # Recreate cabinet dimensions and name labels
          entities.grep(Sketchup::Group).each do |group|
            next unless group.get_attribute('DCC', 'is_cabinet')
            width  = group.get_attribute('DCC', 'width')
            depth  = group.get_attribute('DCC', 'depth')
            height = group.get_attribute('DCC', 'height')
            cabinet_name = group.get_attribute('DCC', 'cabinet_name') || group.name.to_s
            next unless width && depth && height
            
            # Ensure old dimensions/labels are removed to avoid duplicates
            remove_cabinet_dimensions(group)
            remove_cabinet_name_label(group)
            
            add_cabinet_dimensions(group, width, depth, height)
            add_cabinet_name_label(group, cabinet_name, width, depth, height)
          end
          
          # Recreate panel dimensions for panels (standalone and panel-marked components)
          entities.grep(Sketchup::ComponentInstance).each do |instance|
            is_panel = instance.get_attribute('DCC', 'is_standalone_panel') ||
                       instance.definition.get_attribute('DCC', 'is_panel')
            next unless is_panel
            
            width = instance.get_attribute('DCC', 'width') ||
                    instance.definition.get_attribute('DCC', 'width')
            height = instance.get_attribute('DCC', 'height') ||
                     instance.definition.get_attribute('DCC', 'height')
            thickness = instance.get_attribute('DCC', 'thickness') ||
                        instance.definition.get_attribute('DCC', 'depth')
            next unless width && height && thickness
            
            # Ensure old dimensions are removed to avoid duplicates
            remove_panel_dimensions(instance)
            
            add_panel_dimensions(instance, width, height, thickness)
          end
          
          model.commit_operation
        rescue => e
          model.abort_operation
          UI.messagebox("Error showing DCC dimensions and names: #{e.message}")
        end
      end
      
      # Upload panels from Excel/CSV file
      def upload_panels_from_file
        file_path = UI.openpanel('Select CSV/Excel File', '', 'CSV Files|*.csv||')
        return unless file_path && File.exist?(file_path)
        
        begin
          rows = CSV.read(file_path, headers: true, encoding: 'UTF-8')
          original_headers = rows.headers
          
          # Normalize headers for case-insensitive matching
          header_map = {}
          original_headers.each do |h|
            normalized = h.to_s.strip.downcase
            header_map[normalized] = h
          end
          
          success_count = 0
          error_count = 0
          
          model = Sketchup.active_model
          model.start_operation('Bulk Create Panels', true)
          
          rows.each_with_index do |row, index|
            begin
              # Helper to get value by various header name possibilities
              get_value = lambda do |possible_headers, default|
                possible_headers.each do |header|
                  normalized = header.to_s.strip.downcase
                  original_header = header_map[normalized]
                  if original_header && row[original_header]
                    value = row[original_header].to_s.strip
                    return value unless value.empty?
                  end
                end
                default
              end
              
              # Map headers to parameters - try various header name variations
              params = {
                'name' => get_value.call(['name', 'panel name', 'panelname', 'panel'], "Panel #{index + 1}"),
                'width' => get_value.call(['width', 'w'], '600').to_f,
                'height' => get_value.call(['height', 'h'], '720').to_f,
                'thickness' => get_value.call(['thickness', 't'], '18').to_f
              }
              
              create_standalone_panel(params)
              success_count += 1
            rescue => e
              error_count += 1
              UI.messagebox("Error on row #{index + 2}: #{e.message}\n\n#{e.backtrace.first}")
            end
          end
          
          model.commit_operation
          UI.messagebox("Bulk import complete!\nSuccess: #{success_count}\nErrors: #{error_count}")
        rescue => e
          UI.messagebox("Error reading file: #{e.message}")
        end
      end
      
      # Helper to parse boolean values
      def parse_boolean(value)
        return true if value.to_s.downcase == 'true' || value.to_s == '1' || value.to_s.downcase == 'yes'
        return false if value.to_s.downcase == 'false' || value.to_s == '0' || value.to_s.downcase == 'no'
        true # Default
      end
      
      # Download cabinet CSV template
      def download_cabinet_template
        file_path = UI.savepanel('Save Cabinet Template CSV', '', 'cabinet_template.csv', 'CSV Files|*.csv||')
        return unless file_path
        
        begin
          CSV.open(file_path, 'w', encoding: 'UTF-8') do |csv|
            # Header row (matches bulk upload order)
            csv << ['Name', 'Width', 'Depth', 'Height', 'Quantity', 'ShelfQty', 'PartitionQty', 'PanelThickness', 'BackThickness', 'BackInset']
            # Sample data rows
            csv << ['C1', '600', '580', '720', '2', '2', '1', '18', '10', '18']
            csv << ['C2', '800', '600', '900', '1', '0', '2', '18', '10', '18']
            csv << ['Cabinet3', '1000', '500', '2000', '3', '4', '3', '20', '12', '20']
          end
          UI.messagebox("Template CSV saved successfully!\n\n#{file_path}")
        rescue => e
          UI.messagebox("Error saving template: #{e.message}")
        end
      end
      
      # Download panel CSV template
      def download_panel_template
        file_path = UI.savepanel('Save Panel Template CSV', '', 'panel_template.csv', 'CSV Files|*.csv||')
        return unless file_path
        
        begin
          CSV.open(file_path, 'w', encoding: 'UTF-8') do |csv|
            # Header row
            csv << ['Name', 'Width', 'Height', 'Quantity', 'Thickness']
            # Sample data rows
            csv << ['Panel1', '600', '720', '2', '18']
            csv << ['Panel2', '800', '900', '1', '20']
            csv << ['SidePanel', '500', '2000', '4', '18']
          end
          UI.messagebox("Template CSV saved successfully!\n\n#{file_path}")
        rescue => e
          UI.messagebox("Error saving template: #{e.message}")
        end
      end

     
      # Update component property
      def update_component_property(component, params)
        model = Sketchup.active_model
        
        unless component.is_a?(Sketchup::ComponentInstance)
          UI.messagebox("Please select a panel component!")
          return
        end
        
        model.start_operation('Update Panel Properties', true)
        
        begin
          definition = component.definition
          
          # Rename instance if requested
          new_name = (params['panelName'] || '').to_s.strip
          if !new_name.empty?
            component.name = new_name
          end
          
          # Get panel type to determine how to update
          panel_type = component.get_attribute('DCC', 'panel_type')
          is_standalone = component.get_attribute('DCC', 'is_standalone_panel')
          
          # For old files or user-created panels: try to detect panel type from name if not set
          if !panel_type || panel_type.empty?
            component_name = definition.name.to_s
            if component_name.match?(/\bLEFT\b/i)
              panel_type = 'left'
              is_standalone = false
            elsif component_name.match?(/\bRIGHT\b/i)
              panel_type = 'right'
              is_standalone = false
            elsif component_name.match?(/\bTOP\b/i)
              panel_type = 'top'
              is_standalone = false
            elsif component_name.match?(/\bBOTTOM\b/i)
              panel_type = 'bottom'
              is_standalone = false
            elsif component_name.match?(/^p\d+/i) || component_name.match?(/\bPanel\b/i)
              is_standalone = true
              panel_type = 'standalone'
            else
              # For user-created panels or unknown panels, default to standalone
              # Check if it's inside a cabinet group - if not, it's standalone
              is_inside_cabinet = false
              begin
                parent = component.parent
                while parent && !parent.is_a?(Sketchup::Model)
                  if parent.is_a?(Sketchup::Group) && (parent.get_attribute('DCC', 'is_cabinet') || parent.get_attribute('DCC', 'cabinet_name'))
                    is_inside_cabinet = true
                    break
                  end
                  parent = parent.respond_to?(:parent) ? parent.parent : nil
                end
              rescue => e
              end
              
              # Default to standalone if can't determine or not in cabinet
              is_standalone = true unless is_inside_cabinet
              panel_type = 'standalone'
            end
            # Set the detected panel type so it's saved
            component.set_attribute('DCC', 'panel_type', panel_type)
            if is_standalone
              component.set_attribute('DCC', 'is_standalone_panel', true)
            end
            # Ensure definition is marked as panel
            definition.set_attribute('DCC', 'is_panel', true) unless definition.get_attribute('DCC', 'is_panel')
          end
          
          # Get new width, height, and thickness from parameters
          new_width = params['width'].to_f.mm
          new_height = params['height'].to_f.mm
          new_thickness = params['panelThickness'].to_f.mm
          
          # Validate dimensions
          if new_width <= 0 || new_height <= 0
            UI.messagebox("Width and Height must be greater than zero!")
            model.abort_operation
            return
          end
          
          # Get current thickness from definition based on panel type
          if panel_type == 'top' || panel_type == 'bottom'
            # Top/bottom: thickness is stored in height attribute
            current_thickness = definition.get_attribute('DCC', 'height')
          elsif panel_type == 'left' || panel_type == 'right'
            # Left/right: thickness is stored in width attribute
            current_thickness = definition.get_attribute('DCC', 'width')
          else
            # Standalone or other: get from thickness or depth
            current_thickness = component.get_attribute('DCC', 'thickness')
            if !current_thickness || current_thickness <= 0
              current_thickness = definition.get_attribute('DCC', 'depth')
            end
          end
          
          # Use new thickness if provided and valid, otherwise keep current
          if new_thickness > 0
            current_thickness = new_thickness
          end
          
          # Fallback if thickness not found
          if !current_thickness || current_thickness <= 0
            current_thickness = 18.mm  # Default thickness
          end
          
          # Remove old dimensions BEFORE rebuilding geometry (for all panel types)
          remove_panel_dimensions(component)
          
          # Map dimensions based on panel type for update
          if panel_type == 'top' || panel_type == 'bottom'
            # Top and bottom panels: create_panel_component(inner_width, depth, thickness)
            actual_width = new_width
            actual_depth = new_height
            actual_height = current_thickness
          elsif panel_type == 'left' || panel_type == 'right'
            # Left and right panels: create_panel_component(thickness, depth, height)
            actual_width = current_thickness
            actual_depth = new_width
            actual_height = new_height
          else
            # Standalone panels or other types
            # Standard: create_panel_component(width, thickness, height)
            actual_width = new_width
            actual_depth = current_thickness
            actual_height = new_height
          end
          
          # Rebuild the panel component definition with new dimensions
          # Clear existing geometry
          definition.entities.clear!
          
          # Recreate panel geometry with new dimensions
          face = definition.entities.add_face([0, 0, 0], [actual_width, 0, 0], [actual_width, actual_depth, 0], [0, actual_depth, 0])
          face.pushpull(-actual_height)
          
          # Update definition attributes
          definition.set_attribute('DCC', 'width', actual_width)
          definition.set_attribute('DCC', 'depth', actual_depth)
          definition.set_attribute('DCC', 'height', actual_height)
          
          # Update instance attributes for standalone panels
          if is_standalone
            component.set_attribute('DCC', 'width', actual_width)
            component.set_attribute('DCC', 'height', actual_height)
            component.set_attribute('DCC', 'thickness', actual_depth)
            
            # Add new dimensions for standalone panels (old ones were removed before rebuild)
            add_panel_dimensions(component, actual_width, actual_height, actual_depth)
          end

          # Preserve original transformation; do not reposition component after rebuild
          
          # Rearrange all standalone panels with 200mm gap if this is a standalone panel
          value = params['rearrangePanels']
          if is_standalone && (value == true || value.to_s == 'true' || value == 1)
            rearrange_all_standalone_panels
          end
          
          # Refresh view
          model.active_view.refresh
          
          model.commit_operation
          UI.messagebox("Panel updated successfully!") unless @suppress_update_messages
        rescue => e
          model.abort_operation
          UI.messagebox("Error updating panel: #{e.message}") unless @suppress_update_messages
        end
      end
      
      # Extract component data for property panel
      def extract_component_data(component)
        definition = component.definition
        
        # Get panel type to determine dimension mapping
        panel_type = component.get_attribute('DCC', 'panel_type')
        is_standalone = component.get_attribute('DCC', 'is_standalone_panel')
        
        # For old files or user-created panels: try to detect panel type from name if not set
        if !panel_type || panel_type.empty?
          component_name = definition.name.to_s
          if component_name.match?(/\bLEFT\b/i)
            panel_type = 'left'
            is_standalone = false
          elsif component_name.match?(/\bRIGHT\b/i)
            panel_type = 'right'
            is_standalone = false
          elsif component_name.match?(/\bTOP\b/i)
            panel_type = 'top'
            is_standalone = false
          elsif component_name.match?(/\bBOTTOM\b/i)
            panel_type = 'bottom'
            is_standalone = false
          elsif component_name.match?(/^p\d+/i) || component_name.match?(/\bPanel\b/i)
            # Likely standalone panel
            is_standalone = true
            panel_type = 'standalone'
          else
            # For user-created panels or unknown panels, default to standalone
            # Check if it's inside a cabinet group - if not, it's standalone
            is_inside_cabinet = false
            begin
              parent = component.parent
              while parent && !parent.is_a?(Sketchup::Model)
                if parent.is_a?(Sketchup::Group) && (parent.get_attribute('DCC', 'is_cabinet') || parent.get_attribute('DCC', 'cabinet_name'))
                  is_inside_cabinet = true
                  break
                end
                parent = parent.respond_to?(:parent) ? parent.parent : nil
              end
            rescue => e
            end
            
            if is_inside_cabinet
              # Inside a cabinet, but unknown type - default to standalone for now
              is_standalone = true
              panel_type = 'standalone'
            else
              # Not inside a cabinet, definitely standalone
              is_standalone = true
              panel_type = 'standalone'
            end
          end
          
          # Set the detected attributes so they're saved
          component.set_attribute('DCC', 'panel_type', panel_type)
          if is_standalone
            component.set_attribute('DCC', 'is_standalone_panel', true)
          end
          definition.set_attribute('DCC', 'is_panel', true) unless definition.get_attribute('DCC', 'is_panel')
        end
        
        # Get raw dimensions from attributes
        attr_width = nil
        attr_depth = nil
        attr_height = nil
        attr_thickness = nil
        
        if is_standalone
          # Standalone panels store width, height, thickness in instance attributes
          attr_width = component.get_attribute('DCC', 'width')
          attr_height = component.get_attribute('DCC', 'height')
          attr_thickness = component.get_attribute('DCC', 'thickness')
          
          # Fallback to definition attributes
          if !attr_width || attr_width <= 0
            attr_width = definition.get_attribute('DCC', 'width')
          end
          if !attr_height || attr_height <= 0
            attr_height = definition.get_attribute('DCC', 'height')
          end
          if !attr_thickness || attr_thickness <= 0
            attr_thickness = definition.get_attribute('DCC', 'depth')
          end
          
          # For standalone panels, depth = thickness
          attr_depth = attr_thickness
        else
          # Cabinet panels - get from definition attributes
          attr_width = definition.get_attribute('DCC', 'width')
          attr_depth = definition.get_attribute('DCC', 'depth')
          attr_height = definition.get_attribute('DCC', 'height')
          attr_thickness = attr_depth  # For cabinet panels, depth = thickness
        end
        
        # For user-created panels or panels without DCC attributes, always use bounding box
        # Check if we have any meaningful attributes
        has_attributes = (attr_width && attr_width > 0) || (attr_height && attr_height > 0) || (attr_thickness && attr_thickness > 0)
        
        if !has_attributes
          # No DCC attributes found - use bounding box for all dimensions
          bbox = component.bounds
          if bbox.valid?
            size = bbox.max - bbox.min
            # Use bounding box dimensions directly
            attr_width = size.x.abs if !attr_width || attr_width <= 0
            attr_depth = size.y.abs if !attr_depth || attr_depth <= 0
            attr_height = size.z.abs if !attr_height || attr_height <= 0
            # For thickness, use smallest dimension
            dims = [size.x.abs, size.y.abs, size.z.abs].sort
            attr_thickness = dims[0] if !attr_thickness || attr_thickness <= 0
          end
        end
        
        # Map dimensions based on panel type
        # For display in property panel, we want:
        # - width: horizontal dimension
        # - height: vertical dimension
        # - thickness: panel thickness
        
        if panel_type == 'top' || panel_type == 'bottom'
          # Top and bottom panels:
          # Created with: create_panel_component(inner_width, depth, thickness)
          # So definition has: width=inner_width, depth=depth, height=thickness
          # Display: width = width value, height = depth value
          # Thickness is stored in 'height' attribute
          width = attr_width
          height = attr_depth
          thickness = attr_height  # For top/bottom, thickness is stored in height attribute
        elsif panel_type == 'left' || panel_type == 'right'
          # Left and right panels:
          # Created with: create_panel_component(thickness, depth, height)
          # So definition has: width=thickness, depth=depth, height=height
          # Display: width = depth value, height = height value
          # Thickness is stored in 'width' attribute (the actual panel thickness)
          width = attr_depth
          height = attr_height
          thickness = attr_width  # For left/right, thickness is stored in width attribute (panel thickness)
        else
          # Standalone panels or other types - use standard mapping
          # width = width, height = height
          width = attr_width
          height = attr_height
          thickness = attr_thickness
        end
        
        # Additional fallback to bounding box if values are still missing after mapping
        # This ensures we always have dimensions even for user-created panels
        if (!width || width <= 0) || (!height || height <= 0) || (!thickness || thickness <= 0)
          bbox = component.bounds
          if bbox.valid?
            size = bbox.max - bbox.min
            dims = [size.x.abs, size.y.abs, size.z.abs].sort
            
            # For standalone panels, use bounding box dimensions directly
            if is_standalone || panel_type == 'standalone'
              if !width || width <= 0
                width = size.x.abs
              end
              if !height || height <= 0
                height = size.z.abs
              end
              if !thickness || thickness <= 0
                thickness = dims[0]  # Smallest dimension
              end
            else
              # For cabinet panels, use bounding box as fallback
              if !width || width <= 0
                width = size.x.abs
              end
              if !height || height <= 0
                height = size.z.abs
              end
              if !thickness || thickness <= 0
                thickness = dims[0]  # Smallest dimension
              end
            end
          end
        end
        
        # Convert to mm for display
        width_mm = width ? width.to_mm.round(2) : 0
        height_mm = height ? height.to_mm.round(2) : 0
        thickness_mm = thickness ? thickness.to_mm.round(2) : 18
        
        panel_type = panel_type || 'standalone'
        
        display_name = component.name.to_s.strip
        display_name = definition.name.to_s if display_name.nil? || display_name.empty?
        
        result = {
          name: display_name,
          width: width_mm.round(2),
          height: height_mm.round(2),
          thickness: thickness_mm.round(2),
          panelType: panel_type
        }
        
        # Add height adjustment option for top/bottom panels
        if panel_type == 'top' || panel_type == 'bottom'
          # Get current Y position (depth position) to determine reference point
          current_y = component.transformation.origin.y
          # Default to 'front' (change from back) if panel is at y=0
          result[:heightAdjust] = (current_y == 0) ? 'front' : 'end'
        end
        
        # Add width adjustment option for left/right panels
        if panel_type == 'left' || panel_type == 'right'
          # Get current Y position (depth position) to determine reference point
          current_y = component.transformation.origin.y
          # Default to 'front' (change from back) if panel is at y=0
          result[:widthAdjust] = (current_y == 0) ? 'front' : 'back'
        end
        
        result
      end
      
      # Rebuild cabinet with new parameters
      def rebuild_cabinet(cabinet_group)
        # Clear and recreate panels with new dimensions
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        panel_overlap = cabinet_group.get_attribute('DCC', 'panel_overlap') || 'none'
        support_panel_count = cabinet_group.get_attribute('DCC', 'support_panel_count') || 0
        support_panel_height = cabinet_group.get_attribute('DCC', 'support_panel_height') || 100.mm
        
        # Remove old dimensions and name label before rebuilding
        remove_cabinet_dimensions(cabinet_group)
        remove_cabinet_name_label(cabinet_group)
        
        # Clear existing panels
        cabinet_group.entities.clear!
        
        # Recreate panels with overlap setting
        create_left_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
        create_right_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
        create_bottom_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
        create_top_panel(cabinet_group, cabinet_name, width, depth, height, panel_thickness, panel_overlap)
        create_back_panel(cabinet_group, cabinet_name, width, depth, height, back_thickness, back_inset)
        
        # Recreate support panels if specified
        if support_panel_count > 0
          create_support_panels(cabinet_group, cabinet_name, width, depth, height, panel_thickness, support_panel_count, support_panel_height)
        end
        
        # Do NOT recreate dimensions or name labels automatically here; they
        # can be added on demand using 'Show All DCC Dimensions & Names'.
      end
      
      # Show cabinet action selection dialog
      def show_cabinet_action_dialog
        model = Sketchup.active_model
        selection = model.selection.first
        
        # Check if a panel/component is selected (but not a shelf/partition)
        if selection && selection.is_a?(Sketchup::ComponentInstance)
          # Check if it's a shelf/partition first
          panel_type = selection.get_attribute('DCC', 'panel_type')
          if panel_type == 'shelf' || panel_type == 'section_shelf' || panel_type == 'partition' || panel_type == 'drawer_partition'
            selected_shelf_or_partition = selection
            cabinet_group = find_parent_cabinet(selection)
            if cabinet_group
              show_relative_action_dialog(cabinet_group, selected_shelf_or_partition)
              return
            end
          elsif is_panel_component?(selection)
            show_component_action_dialog(selection)
            return
          end
        end
        
        # Check if a cabinet group is selected
        cabinet_group = is_cabinet_group?(selection) ? selection : nil
        
        
        # If we have a cabinet selected, show main cabinet options
        if cabinet_group
          show_main_cabinet_action_dialog(cabinet_group)
          return
        end
        
        # No valid selection
        UI.messagebox("Please select a cabinet first, or select a shelf/partition to add items relative to it.")
      end
      
      # Show main cabinet action dialog (when cabinet is selected)
      def show_main_cabinet_action_dialog(cabinet_group)
        prompts = ["Action"]
        defaults = ["Edit Cabinet Properties"]
        list = ["Edit Cabinet Properties|Add Shelf|Insert Drawer Partition|Select Section"]
        
        result = UI.inputbox(prompts, defaults, list, "Cabinet Action")
        return unless result
        
        action = result[0]
        
        case action
        when "Edit Cabinet Properties"
          show_edit_cabinet_properties_dialog(cabinet_group)
        when "Add Shelf"
          show_add_shelf_at_position_dialog(cabinet_group)
        when "Insert Drawer Partition"
          show_insert_drawer_partition_dialog(cabinet_group)
        when "Select Section"
          show_select_section_dialog(cabinet_group)
        end
      end
      
      # Show component/panel action dialog (when panel is selected)
      def show_component_action_dialog(component)
        prompts = ["Action"]
        defaults = ["Component Properties"]
        list = ["Component Properties"]
        
        result = UI.inputbox(prompts, defaults, list, "Component Action")
        return unless result
        
        action = result[0]
        
        case action
        when "Component Properties"
          show_property_panel(component)
        end
      end
      
      # Show dialog to edit cabinet properties
      def show_edit_cabinet_properties_dialog(cabinet_group)
        dialog = get_or_create_dialog('edit_cabinet_properties', 'Edit Cabinet Properties', 450, 750)
        dialog.set_url(File.join(__dir__, 'ui', 'edit_cabinet_properties.html'))
        
        # Get current cabinet properties
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name') || 'Unknown'
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        panel_overlap = cabinet_group.get_attribute('DCC', 'panel_overlap') || 'none'
        support_panel_count = cabinet_group.get_attribute('DCC', 'support_panel_count') || 0
        support_panel_height = cabinet_group.get_attribute('DCC', 'support_panel_height') || 100.mm
        
        # Convert to mm for display
        width_mm = width ? width.to_mm.round(1) : 0
        depth_mm = depth ? depth.to_mm.round(1) : 0
        height_mm = height ? height.to_mm.round(1) : 0
        panel_thickness_mm = panel_thickness ? panel_thickness.to_mm.round(1) : 18
        back_thickness_mm = back_thickness ? back_thickness.to_mm.round(1) : 10
        back_inset_mm = back_inset ? back_inset.to_mm.round(1) : 18
        support_panel_count_int = support_panel_count.to_i
        support_panel_height_mm = support_panel_height ? support_panel_height.to_mm.round(1) : 100
        
        # Escape cabinet name for JavaScript
        cabinet_name_escaped = cabinet_name.gsub("'", "\\'")
        
        # Handle update callback
        dialog.add_action_callback('updateCabinetProperties') do |action_context, params|
          update_cabinet_properties(cabinet_group, params)
        end
        
        dialog.show
        
        # Populate form fields after dialog is shown (with a small delay to ensure DOM is ready)
        js_code = <<-JS
          setTimeout(function() {
            document.getElementById('cabinetName').textContent = '#{cabinet_name_escaped}';
            document.getElementById('cabinetNameInput').value = '#{cabinet_name_escaped}';
            document.getElementById('width').value = #{width_mm};
            document.getElementById('depth').value = #{depth_mm};
            document.getElementById('height').value = #{height_mm};
            document.getElementById('panelThickness').value = #{panel_thickness_mm};
            document.getElementById('backThickness').value = #{back_thickness_mm};
            document.getElementById('backInset').value = #{back_inset_mm};
            document.getElementById('panelOverlap').value = '#{panel_overlap}';
            var enableSupportPanels = #{support_panel_count_int > 0 ? 'true' : 'false'};
            document.getElementById('enableSupportPanels').checked = enableSupportPanels;
            document.getElementById('supportPanelOptions').style.display = enableSupportPanels ? 'block' : 'none';
            document.getElementById('supportPanelCount').value = #{support_panel_count_int > 0 ? support_panel_count_int : 2};
            document.getElementById('supportPanelHeight').value = #{support_panel_height_mm};
          }, 100);
        JS
        
        dialog.execute_script(js_code)
      end
      
      # Update cabinet properties
      def update_cabinet_properties(cabinet_group, params)
        model = Sketchup.active_model
        
        unless cabinet_group && cabinet_group.get_attribute('DCC', 'is_cabinet')
          UI.messagebox("Invalid cabinet selection!")
          return
        end
        
        model.start_operation('Update Cabinet Properties', true)
        
        # Get new values
        new_name = params['cabinetName'].to_s.strip
        new_width = params['width'].to_f.mm
        new_depth = params['depth'].to_f.mm
        new_height = params['height'].to_f.mm
        new_panel_thickness = params['panelThickness'].to_f.mm
        new_back_thickness = params['backThickness'].to_f.mm
        new_back_inset = params['backInset'].to_f.mm
        new_support_panel_count = (params['supportPanelCount'] || 0).to_i
        new_support_panel_height = (params['supportPanelHeight'] || 100).to_f.mm
        
        # Validate dimensions
        if new_width < 100.mm || new_depth < 100.mm || new_height < 100.mm
          UI.messagebox("Dimensions must be at least 100mm!")
          model.abort_operation
          return
        end
        
        if new_panel_thickness < 5.mm || new_panel_thickness > 50.mm
          UI.messagebox("Panel thickness must be between 5mm and 50mm!")
          model.abort_operation
          return
        end
        
        # Update attributes
        if new_name && !new_name.empty?
          cabinet_group.set_attribute('DCC', 'cabinet_name', new_name)
          cabinet_group.name = "#{new_name} Cabinet"
        end
        
        cabinet_group.set_attribute('DCC', 'width', new_width)
        cabinet_group.set_attribute('DCC', 'depth', new_depth)
        cabinet_group.set_attribute('DCC', 'height', new_height)
        cabinet_group.set_attribute('DCC', 'panel_thickness', new_panel_thickness)
        cabinet_group.set_attribute('DCC', 'back_thickness', new_back_thickness)
        cabinet_group.set_attribute('DCC', 'back_inset', new_back_inset)
        panel_overlap = params['panelOverlap'] || 'none'
        cabinet_group.set_attribute('DCC', 'panel_overlap', panel_overlap)
        cabinet_group.set_attribute('DCC', 'support_panel_count', new_support_panel_count)
        cabinet_group.set_attribute('DCC', 'support_panel_height', new_support_panel_height)
        
        # Rebuild cabinet with new dimensions
        rebuild_cabinet(cabinet_group)
        
        model.commit_operation
        
        UI.messagebox("Cabinet properties updated successfully!")
      end
      
      # Get currently selected cabinet
      def get_selected_cabinet
        model = Sketchup.active_model
        selection = model.selection.first
        
        return nil unless selection
        return selection if is_cabinet_group?(selection)

        nil
      end
      
      def find_parent_cabinet(entity)
        # Check if entity is in a group (cabinet)
        parent = entity.parent
        
        # Traverse parent hierarchy until we find a cabinet group or reach the Model
        while parent && !parent.is_a?(Sketchup::Model)
          if parent.is_a?(Sketchup::Group)
            # Check if it's a cabinet by either is_cabinet attribute or cabinet_name
            if parent.get_attribute('DCC', 'is_cabinet') || parent.get_attribute('DCC', 'cabinet_name')
              return parent
            end
          end
          
          # Move to next parent, but check if it responds to parent method
          if parent.respond_to?(:parent)
            parent = parent.parent
          else
            break
          end
        end
        
        # If not found by traversing parent, search through all groups
        model = Sketchup.active_model
        model.active_entities.each do |e|
          if e.is_a?(Sketchup::Group)
            if e.entities.include?(entity) && (e.get_attribute('DCC', 'is_cabinet') || e.get_attribute('DCC', 'cabinet_name'))
              return e
            end
          end
        end
        
        nil
      end
      
      # Show dialog for adding items relative to selected shelf/partition
      def show_relative_action_dialog(cabinet_group, selected_item)
        panel_type = selected_item.get_attribute('DCC', 'panel_type')
        is_partition = (panel_type == 'partition' || panel_type == 'drawer_partition')
        is_shelf = (panel_type == 'shelf' || panel_type == 'section_shelf')
        
        if is_shelf
          # For shelves: show "Above Shelf" or "Below Shelf" with Partition/Drawer options
          prompts = ["Action"]
          defaults = ["Above Shelf - Add Partition"]
          list = ["Above Shelf - Add Partition|Above Shelf - Add Drawer|Below Shelf - Add Partition|Below Shelf - Add Drawer"]
          
          result = UI.inputbox(prompts, defaults, list, "Add Item Relative to Shelf")
          return unless result
          
          action = result[0]
          
          if action.include?("Above Shelf")
            position = "Above"
            if action.include?("Partition")
              show_add_partition_relative_dialog(cabinet_group, selected_item, position)
            elsif action.include?("Drawer")
              show_add_drawer_relative_dialog(cabinet_group, selected_item, position)
            end
          elsif action.include?("Below Shelf")
            position = "Below"
            if action.include?("Partition")
              show_add_partition_relative_dialog(cabinet_group, selected_item, position)
            elsif action.include?("Drawer")
              show_add_drawer_relative_dialog(cabinet_group, selected_item, position)
            end
          end
        elsif is_partition
          # For partitions: show "Left of Partition" or "Right of Partition" with Shelf/Drawer options
          prompts = ["Action"]
          defaults = ["Left of Partition - Add Shelf"]
          list = ["Left of Partition - Add Shelf|Left of Partition - Add Drawer|Right of Partition - Add Shelf|Right of Partition - Add Drawer"]
          
          result = UI.inputbox(prompts, defaults, list, "Add Item Relative to Partition")
          return unless result
          
          action = result[0]
          
          if action.include?("Left of Partition")
            position = "Left"
            if action.include?("Shelf")
              show_add_shelf_relative_dialog(cabinet_group, selected_item, position)
            elsif action.include?("Drawer")
              show_add_drawer_relative_dialog(cabinet_group, selected_item, position)
            end
          elsif action.include?("Right of Partition")
            position = "Right"
            if action.include?("Shelf")
              show_add_shelf_relative_dialog(cabinet_group, selected_item, position)
            elsif action.include?("Drawer")
              show_add_drawer_relative_dialog(cabinet_group, selected_item, position)
            end
          end
        end
      end
      
      # Show dialog to insert drawer partitions
      def show_insert_drawer_partition_dialog(cabinet_group)
        prompts = ["Number of Partitions", "Partition Thickness (mm)"]
        defaults = ["1", "18"]
        
        result = UI.inputbox(prompts, defaults, "Insert Drawer Partitions")
        return unless result
        
        num_partitions = result[0].to_i
        partition_thickness = result[1].to_f.mm
        
        if num_partitions <= 0
          UI.messagebox("Number of partitions must be greater than 0.")
          return
        end
        
        insert_drawer_partitions(cabinet_group, num_partitions, partition_thickness)
      end
      
      # Insert drawer partitions (vertical partitions for drawer divisions)
      def insert_drawer_partitions(cabinet_group, num_partitions, partition_thickness)
        model = Sketchup.active_model
        model.start_operation('Insert Drawer Partitions', true)
        
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        # Calculate partition dimensions
        partition_depth = depth - back_inset - back_thickness
        partition_height = height - (2 * panel_thickness)
        inner_width = width - (2 * panel_thickness)
        
        # Check if we have enough space
        if inner_width < (num_partitions * partition_thickness) + (partition_thickness * 2)
          UI.messagebox("Cabinet is too narrow for #{num_partitions} partitions.")
          model.abort_operation
          return
        end
        
        # Calculate spacing (equal spacing)
        spacing = (inner_width - (num_partitions * partition_thickness)) / (num_partitions + 1)
        
        # Get existing drawer partitions to avoid duplicates
        existing_partitions = get_drawer_partitions(cabinet_group)
        existing_count = existing_partitions.length
        
        # Add new partitions
        (1..num_partitions).each do |i|
          partition_index = existing_count + i
          partition_x = panel_thickness + (i * spacing) + ((i - 1) * partition_thickness)
          
          partition_def = create_panel_component("#{cabinet_name} - DRAWER PARTITION #{partition_index}", partition_thickness, partition_depth, partition_height)
          instance = cabinet_group.entities.add_instance(partition_def, [partition_x, 0, panel_thickness])
          instance.set_attribute('DCC', 'panel_type', 'drawer_partition')
          instance.set_attribute('DCC', 'partition_index', partition_index)
        end
        
        model.commit_operation
        UI.messagebox("#{num_partitions} drawer partition(s) inserted successfully!")
      end
      
      # Get all drawer partitions from cabinet
      def get_drawer_partitions(cabinet_group)
        partitions = []
        cabinet_group.entities.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'panel_type') == 'drawer_partition'
              transformation = entity.transformation
              x_position = transformation.origin.x
              partitions << {
                instance: entity,
                x_position: x_position,
                index: entity.get_attribute('DCC', 'partition_index') || 0
              }
            end
          end
        end
        partitions.sort_by { |p| p[:x_position] }
      end
      
      # Get cabinet sections (left, middle sections, right) based on partitions
      def get_cabinet_sections(cabinet_group)
        width = cabinet_group.get_attribute('DCC', 'width')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        
        partitions = get_drawer_partitions(cabinet_group)
        inner_width = width - (2 * panel_thickness)
        
        sections = []
        
        if partitions.empty?
          # No partitions - single section
          sections << {
            name: "Full Width",
            index: 0,
            left_x: panel_thickness,
            right_x: width - panel_thickness,
            width: inner_width
          }
        else
          # Left section (before first partition)
          first_partition_x = partitions.first[:x_position]
          left_section_width = first_partition_x - panel_thickness
          if left_section_width > 0
            sections << {
              name: "Left Section",
              index: 0,
              left_x: panel_thickness,
              right_x: first_partition_x,
              width: left_section_width
            }
          end
          
          # Middle sections (between partitions)
          partitions.each_with_index do |partition, idx|
            next if idx == partitions.length - 1
            
            left_x = partition[:x_position] + partition[:instance].definition.get_attribute('DCC', 'width')
            right_x = partitions[idx + 1][:x_position]
            section_width = right_x - left_x
            
            if section_width > 0
              sections << {
                name: "Middle Section #{idx + 1}",
                index: idx + 1,
                left_x: left_x,
                right_x: right_x,
                width: section_width
              }
            end
          end
          
          # Right section (after last partition)
          last_partition = partitions.last
          last_partition_width = last_partition[:instance].definition.get_attribute('DCC', 'width')
          right_section_left_x = last_partition[:x_position] + last_partition_width
          right_section_width = (width - panel_thickness) - right_section_left_x
          
          if right_section_width > 0
            sections << {
              name: "Right Section",
              index: sections.length,
              left_x: right_section_left_x,
              right_x: width - panel_thickness,
              width: right_section_width
            }
          end
        end
        
        sections
      end
      
      # Show dialog to select a section
      def show_select_section_dialog(cabinet_group)
        sections = get_cabinet_sections(cabinet_group)
        
        if sections.empty?
          UI.messagebox("No sections found. Please add drawer partitions first.")
          return
        end
        
        section_names = sections.map { |s| s[:name] }
        section_list = section_names.join("|")
        
        prompts = ["Select Section"]
        defaults = [section_names.first]
        list = [section_list]
        
        result = UI.inputbox(prompts, defaults, list, "Select Partition Section")
        return unless result
        
        selected_name = result[0]
        selected_section = sections.find { |s| s[:name] == selected_name }
        
        return unless selected_section
        
        show_section_action_dialog(cabinet_group, selected_section)
      end
      
      # Show dialog for section action (add shelf or drawer)
      def show_section_action_dialog(cabinet_group, section)
        prompts = ["Action"]
        defaults = ["Add Shelf"]
        list = ["Add Shelf|Add Drawer"]
        
        result = UI.inputbox(prompts, defaults, list, "Section Action: #{section[:name]}")
        return unless result
        
        action = result[0]
        
        case action
        when "Add Shelf"
          show_add_shelf_to_section_dialog(cabinet_group, section)
        when "Add Drawer"
          show_add_drawer_to_section_dialog(cabinet_group, section)
        end
      end
      
      # Show dialog to add shelf to cabinet
      def show_add_shelf_dialog(cabinet_group)
        prompts = ["Number of Shelves", "Shelf Thickness (mm)"]
        defaults = ["1", "18"]
        
        result = UI.inputbox(prompts, defaults, "Add Shelves")
        return unless result
        
        num_shelves = result[0].to_i
        shelf_thickness = result[1].to_f.mm
        
        if num_shelves <= 0
          UI.messagebox("Number of shelves must be greater than 0.")
          return
        end
        
        add_shelves(cabinet_group, num_shelves, shelf_thickness)
        UI.messagebox("#{num_shelves} shelf/shelves added successfully!")
      end
      
      # Show dialog to add shelf at specific position
      def show_add_shelf_at_position_dialog(cabinet_group)
        height = cabinet_group.get_attribute('DCC', 'height')
        width = cabinet_group.get_attribute('DCC', 'width')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        
        prompts = ["Height from Bottom (mm)", "Distance from Left Panel (mm)", "Shelf Width (mm)", "Shelf Thickness (mm)"]
        defaults = [(height / 2).to_mm.to_s, "0", (width - 2 * panel_thickness).to_mm.to_s, "18"]
        
        result = UI.inputbox(prompts, defaults, "Add Shelf")
        return unless result
        
        height_from_bottom = result[0].to_f.mm
        distance_from_left = result[1].to_f.mm
        shelf_width = result[2].to_f.mm
        shelf_thickness = result[3].to_f.mm
        
        # Validate
        if height_from_bottom < 0 || height_from_bottom > height
          UI.messagebox("Height from bottom must be between 0 and #{height.to_mm}mm.")
          return
        end
        
        shelf_instance = add_shelf_at_position(cabinet_group, height_from_bottom, distance_from_left, shelf_width, shelf_thickness)
        
        if shelf_instance
          UI.messagebox("Shelf added successfully!")
          # After adding shelf, show options to add partition or drawer
          show_shelf_followup_dialog(cabinet_group, shelf_instance)
        end
      end
      
      # Show follow-up dialog after adding shelf (to add partition or drawer)
      def show_shelf_followup_dialog(cabinet_group, shelf_instance)
        prompts = ["Action"]
        defaults = ["Above Shelf - Add Partition"]
        list = ["Above Shelf - Add Partition|Above Shelf - Add Drawer|Below Shelf - Add Partition|Below Shelf - Add Drawer|Done"]
        
        result = UI.inputbox(prompts, defaults, list, "Add Item to Shelf")
        return unless result
        
        action = result[0]
        return if action == "Done"
        
        if action.include?("Above Shelf")
          position = "Above"
          if action.include?("Partition")
            show_add_partition_relative_dialog(cabinet_group, shelf_instance, position)
          elsif action.include?("Drawer")
            show_add_drawer_relative_dialog(cabinet_group, shelf_instance, position)
          end
        elsif action.include?("Below Shelf")
          position = "Below"
          if action.include?("Partition")
            show_add_partition_relative_dialog(cabinet_group, shelf_instance, position)
          elsif action.include?("Drawer")
            show_add_drawer_relative_dialog(cabinet_group, shelf_instance, position)
          end
        end
        
        # After adding item, ask if they want to add more
        if action != "Done"
          response = UI.messagebox("Item added! Add another item to this shelf?", MB_YESNO)
          # MB_YESNO returns 6 for Yes, 7 for No
          if response == 6
            show_shelf_followup_dialog(cabinet_group, shelf_instance)
          end
        end
      end
      
      # Add shelf at specific position
      def add_shelf_at_position(cabinet_group, height_from_bottom, distance_from_left, shelf_width, shelf_thickness)
        model = Sketchup.active_model
        model.start_operation('Add Shelf at Position', true)
        
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        shelf_depth = depth - back_inset - back_thickness
        shelf_z = panel_thickness + height_from_bottom
        shelf_x = panel_thickness + distance_from_left
        
        # Calculate maximum allowed values
        max_inner_width = width - (2 * panel_thickness)
        max_shelf_right = width - panel_thickness
        
        # Validate position
        if shelf_x < panel_thickness
          UI.messagebox("Shelf position is too far left. Distance from left panel must be >= 0.")
          model.abort_operation
          return nil
        end
        
        if shelf_x + shelf_width > max_shelf_right + 0.1.mm # Allow small tolerance for floating point
          available_width = max_shelf_right - shelf_x
          UI.messagebox("Shelf extends beyond cabinet width.\n\nAvailable width from this position: #{available_width.to_mm.round(1)}mm\nShelf width: #{shelf_width.to_mm.round(1)}mm\n\nPlease adjust distance from left or shelf width.")
          model.abort_operation
          return nil
        end
        
        if shelf_z < panel_thickness
          UI.messagebox("Shelf position is too low. Height from bottom must be >= 0.")
          model.abort_operation
          return nil
        end
        
        if shelf_z + shelf_thickness > height - panel_thickness + 0.1.mm # Allow small tolerance
          available_height = height - panel_thickness - shelf_z
          UI.messagebox("Shelf extends beyond cabinet height.\n\nAvailable height from this position: #{available_height.to_mm.round(1)}mm\nShelf height: #{shelf_thickness.to_mm.round(1)}mm\n\nPlease adjust height from bottom or shelf thickness.")
          model.abort_operation
          return nil
        end
        
        # Get existing shelf count
        existing_shelves = cabinet_group.entities.grep(Sketchup::ComponentInstance).select do |e|
          e.get_attribute('DCC', 'panel_type') == 'shelf' || e.get_attribute('DCC', 'panel_type') == 'section_shelf'
        end
        shelf_index = existing_shelves.length + 1
        
        shelf_def = create_panel_component("#{cabinet_name} - SHELF AT #{height_from_bottom.to_mm}mm", shelf_width, shelf_depth, shelf_thickness)
        instance = cabinet_group.entities.add_instance(shelf_def, [shelf_x, 0, shelf_z])
        instance.set_attribute('DCC', 'panel_type', 'shelf')
        instance.set_attribute('DCC', 'shelf_position', height_from_bottom)
        
        model.commit_operation
        
        # Return the shelf instance so we can show follow-up options
        return instance
      end
      
      # Show dialog to add partition at specific position
      def show_add_partition_at_position_dialog(cabinet_group)
        height = cabinet_group.get_attribute('DCC', 'height')
        width = cabinet_group.get_attribute('DCC', 'width')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        
        prompts = ["Distance from Left Panel (mm)", "Partition Height from Bottom (mm)", "Partition Thickness (mm)"]
        defaults = [(width / 2).to_mm.to_s, "0", "18"]
        
        result = UI.inputbox(prompts, defaults, "Add Partition at Position")
        return unless result
        
        distance_from_left = result[0].to_f.mm
        height_from_bottom = result[1].to_f.mm
        partition_thickness = result[2].to_f.mm
        
        # Validate
        if distance_from_left < 0 || distance_from_left > width - panel_thickness
          UI.messagebox("Distance from left must be between 0 and #{width.to_mm}mm.")
          return
        end
        
        add_partition_at_position(cabinet_group, distance_from_left, height_from_bottom, partition_thickness)
        UI.messagebox("Partition added successfully!")
      end
      
      # Add partition at specific position
      def add_partition_at_position(cabinet_group, distance_from_left, height_from_bottom, partition_thickness)
        model = Sketchup.active_model
        model.start_operation('Add Partition at Position', true)
        
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        partition_depth = depth - back_inset - back_thickness
        partition_height = height - (2 * panel_thickness) - height_from_bottom
        partition_x = panel_thickness + distance_from_left
        partition_z = panel_thickness + height_from_bottom
        
        # Validate position
        if partition_x + partition_thickness > width - panel_thickness
          UI.messagebox("Partition extends beyond cabinet width. Adjust distance from left.")
          model.abort_operation
          return
        end
        
        if partition_height <= 0
          UI.messagebox("Partition height is invalid. Adjust height from bottom.")
          model.abort_operation
          return
        end
        
        # Get existing partition count
        existing_partitions = cabinet_group.entities.grep(Sketchup::ComponentInstance).select do |e|
          e.get_attribute('DCC', 'panel_type') == 'partition'
        end
        partition_index = existing_partitions.length + 1
        
        partition_def = create_panel_component("#{cabinet_name} - PARTITION AT #{distance_from_left.to_mm}mm", partition_thickness, partition_depth, partition_height)
        instance = cabinet_group.entities.add_instance(partition_def, [partition_x, 0, partition_z])
        instance.set_attribute('DCC', 'panel_type', 'partition')
        instance.set_attribute('DCC', 'partition_position', distance_from_left)
        
        model.commit_operation
      end
      
      # Show dialog to add shelf relative to selected item
      def show_add_shelf_relative_dialog(cabinet_group, selected_item, position)
        panel_type = selected_item.get_attribute('DCC', 'panel_type')
        is_shelf = (panel_type == 'shelf' || panel_type == 'section_shelf')
        is_partition = (panel_type == 'partition' || panel_type == 'drawer_partition')
        
        if is_shelf
          # Adding shelf above/below another shelf
          transformation = selected_item.transformation
          selected_z = transformation.origin.z
          selected_height = selected_item.definition.get_attribute('DCC', 'height') || 18.mm
          
          prompts = ["Distance from Selected Shelf (mm)", "Shelf Width (mm)", "Shelf Thickness (mm)"]
          defaults = ["50", "600", "18"]
          
          result = UI.inputbox(prompts, defaults, "Add Shelf #{position} Selected Shelf")
          return unless result
          
          distance = result[0].to_f.mm
          shelf_width = result[1].to_f.mm
          shelf_thickness = result[2].to_f.mm
          
          # Calculate new Z position
          if position == "Above"
            new_z = selected_z + selected_height + distance
          else # Below
            new_z = selected_z - distance - shelf_thickness
          end
          
          # Get X position from selected shelf
          selected_x = transformation.origin.x
          distance_from_left = selected_x - cabinet_group.get_attribute('DCC', 'panel_thickness')
          
          height = cabinet_group.get_attribute('DCC', 'height')
          panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
          height_from_bottom = new_z - panel_thickness
          
          add_shelf_at_position(cabinet_group, height_from_bottom, distance_from_left, shelf_width, shelf_thickness)
          UI.messagebox("Shelf added #{position} selected shelf successfully!")
        elsif is_partition
          # Adding shelf left/right of partition (in a section)
          transformation = selected_item.transformation
          selected_x = transformation.origin.x
          selected_width = selected_item.definition.get_attribute('DCC', 'width') || 18.mm
          
          # Get section info if available
          section_index = selected_item.get_attribute('DCC', 'section_index')
          
          prompts = ["Distance from Selected Partition (mm)", "Shelf Height from Bottom (mm)", "Shelf Width (mm)", "Shelf Thickness (mm)"]
          defaults = ["0", "300", "300", "18"]
          
          result = UI.inputbox(prompts, defaults, "Add Shelf #{position} Partition")
          return unless result
          
          distance = result[0].to_f.mm
          height_from_bottom = result[1].to_f.mm
          shelf_width = result[2].to_f.mm
          shelf_thickness = result[3].to_f.mm
          
          # Calculate X position based on partition and position
          panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
          
          if position == "Right"
            # Add shelf to the right of partition (in the section to the right)
            new_x = selected_x + selected_width + distance
          else # Left
            # Add shelf to the left of partition (in the section to the left)
            new_x = selected_x - distance - shelf_width
          end
          
          distance_from_left = new_x - panel_thickness
          
          add_shelf_at_position(cabinet_group, height_from_bottom, distance_from_left, shelf_width, shelf_thickness)
          UI.messagebox("Shelf added #{position} of partition successfully!")
        end
      end
      
      # Show dialog to add partition relative to selected item
      def show_add_partition_relative_dialog(cabinet_group, selected_item, position)
        panel_type = selected_item.get_attribute('DCC', 'panel_type')
        is_shelf = (panel_type == 'shelf' || panel_type == 'section_shelf')
        
        if is_shelf
          # Adding partition above/below shelf (vertical partition starting from shelf)
          transformation = selected_item.transformation
          selected_z = transformation.origin.z
          selected_height = selected_item.definition.get_attribute('DCC', 'height') || 18.mm
          
          prompts = ["Distance from Selected Shelf (mm)", "Partition Height from Shelf (mm)", "Partition Thickness (mm)"]
          defaults = ["0", "200", "18"]
          
          result = UI.inputbox(prompts, defaults, "Add Partition #{position} Shelf")
          return unless result
          
          distance = result[0].to_f.mm
          partition_height = result[1].to_f.mm
          partition_thickness = result[2].to_f.mm
          
          # Get X position from shelf (use shelf width for positioning)
          selected_x = transformation.origin.x
          selected_width = selected_item.definition.get_attribute('DCC', 'width') || 600.mm
          
          # Position partition at shelf position (can be adjusted)
          panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
          distance_from_left = selected_x - panel_thickness
          
          # Calculate height from bottom based on position
          if position == "Above"
            height_from_bottom = selected_z + selected_height + distance - panel_thickness
          else # Below
            height_from_bottom = selected_z - partition_height - distance - panel_thickness
          end
          
          # Add partition starting from calculated position
          add_partition_from_shelf(cabinet_group, selected_item, position, distance, partition_height, partition_thickness)
          UI.messagebox("Partition added #{position} shelf successfully!")
        else
          # Adding partition left/right of partition (horizontal positioning)
          transformation = selected_item.transformation
          selected_x = transformation.origin.x
          selected_width = selected_item.definition.get_attribute('DCC', 'width') || 18.mm
          
          prompts = ["Distance from Selected Partition (mm)", "Partition Thickness (mm)"]
          defaults = ["50", "18"]
          
          result = UI.inputbox(prompts, defaults, "Add Partition #{position} Selected Partition")
          return unless result
          
          distance = result[0].to_f.mm
          partition_thickness = result[1].to_f.mm
          
          # Calculate new X position
          if position == "Right"
            new_x = selected_x + selected_width + distance
          else # Left
            new_x = selected_x - distance - partition_thickness
          end
          
          panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
          distance_from_left = new_x - panel_thickness
          height_from_bottom = 0.mm # Start from bottom
          
          add_partition_at_position(cabinet_group, distance_from_left, height_from_bottom, partition_thickness)
          UI.messagebox("Partition added #{position} selected partition successfully!")
        end
      end
      
      # Add partition relative to shelf (above or below)
      def add_partition_from_shelf(cabinet_group, shelf_item, position, distance, partition_height, partition_thickness)
        model = Sketchup.active_model
        model.start_operation('Add Partition from Shelf', true)
        
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        transformation = shelf_item.transformation
        shelf_z = transformation.origin.z
        shelf_height = shelf_item.definition.get_attribute('DCC', 'height') || 18.mm
        shelf_x = transformation.origin.x
        shelf_width = shelf_item.definition.get_attribute('DCC', 'width') || 600.mm
        
        partition_depth = depth - back_inset - back_thickness
        
        # Calculate partition position
        if position == "Above"
          partition_z = shelf_z + shelf_height + distance
          partition_height_actual = [partition_height, height - panel_thickness - partition_z].min
        else # Below
          partition_z = shelf_z - partition_height - distance
          partition_height_actual = partition_height
        end
        
        # Validate
        if partition_z < panel_thickness || partition_z + partition_height_actual > height - panel_thickness
          UI.messagebox("Partition extends beyond cabinet bounds. Adjust distance or height.")
          model.abort_operation
          return
        end
        
        # Position partition at shelf X position (or can be adjusted)
        partition_x = shelf_x
        
        # Get existing partition count
        existing_partitions = cabinet_group.entities.grep(Sketchup::ComponentInstance).select do |e|
          e.get_attribute('DCC', 'panel_type') == 'partition'
        end
        partition_index = existing_partitions.length + 1
        
        partition_def = create_panel_component("#{cabinet_name} - PARTITION #{position} SHELF #{partition_index}", partition_thickness, partition_depth, partition_height_actual)
        instance = cabinet_group.entities.add_instance(partition_def, [partition_x, 0, partition_z])
        instance.set_attribute('DCC', 'panel_type', 'partition')
        instance.set_attribute('DCC', 'partition_position', partition_x - panel_thickness)
        
        model.commit_operation
      end
      
      # Show dialog to add drawer relative to selected item
      def show_add_drawer_relative_dialog(cabinet_group, selected_item, position)
        panel_type = selected_item.get_attribute('DCC', 'panel_type')
        is_shelf = (panel_type == 'shelf' || panel_type == 'section_shelf')
        is_partition = (panel_type == 'partition' || panel_type == 'drawer_partition')
        
        if is_shelf
          # Adding drawer above/below shelf
          transformation = selected_item.transformation
          selected_z = transformation.origin.z
          selected_height = selected_item.definition.get_attribute('DCC', 'height') || 18.mm
          
          prompts = ["Number of Drawers", "Orientation", "Distance from Selected Shelf (mm)", "Drawer Height (mm)", "Drawer Front Thickness (mm)"]
          defaults = ["1", "Vertical", "50", "100", "18"]
          list = ["", "Vertical|Horizontal", "", "", ""]
          
          result = UI.inputbox(prompts, defaults, list, "Add Drawer #{position} Shelf")
          return unless result
          
          num_drawers = result[0].to_i
          orientation = result[1]
          distance = result[2].to_f.mm
          drawer_height = result[3].to_f.mm
          drawer_front_thickness = result[4].to_f.mm
          
          if num_drawers <= 0
            UI.messagebox("Number of drawers must be greater than 0.")
            return
          end
          
          # Calculate new Z position (for first drawer)
          if position == "Above"
            new_z = selected_z + selected_height + distance
          else # Below
            # For horizontal (stacked), need to account for all drawer heights
            if orientation == "Horizontal"
              total_height = num_drawers * drawer_height
              new_z = selected_z - distance - total_height
            else
              new_z = selected_z - distance - drawer_height
            end
          end
          
          # Get section info from selected shelf (if any)
          section_index = selected_item.get_attribute('DCC', 'section_index')
          
          if section_index && section_index >= 0
            # Shelf is in a section - get section info
            sections = get_cabinet_sections(cabinet_group)
            section = sections.find { |s| s[:index] == section_index }
            if section
              # Add drawers to section at calculated position
              add_drawers_to_section_at_position(cabinet_group, section, new_z, num_drawers, drawer_height, drawer_front_thickness, orientation)
            else
              UI.messagebox("Could not find section. Adding drawer to full cabinet.")
              add_drawers_at_position(cabinet_group, new_z, num_drawers, drawer_height, drawer_front_thickness, orientation)
            end
          else
            # Add drawers to full cabinet
            add_drawers_at_position(cabinet_group, new_z, num_drawers, drawer_height, drawer_front_thickness, orientation)
          end
          
          UI.messagebox("#{num_drawers} drawer(s) added #{position} shelf successfully!")
        elsif is_partition
          # Adding drawer left/right of partition (in a section)
          transformation = selected_item.transformation
          selected_x = transformation.origin.x
          selected_width = selected_item.definition.get_attribute('DCC', 'width') || 18.mm
          
          # Find which section this partition creates
          sections = get_cabinet_sections(cabinet_group)
          
          # Determine which section to use based on position
          target_section = nil
          if position == "Right"
            # Find section to the right of this partition
            target_section = sections.find do |s|
              s[:left_x] >= selected_x + selected_width
            end
          else # Left
            # Find section to the left of this partition
            target_section = sections.find do |s|
              s[:right_x] <= selected_x
            end
          end
          
          if target_section.nil?
            # If no section found, use full cabinet or create a section
            UI.messagebox("No section found #{position} of partition. Please add drawer partitions first.")
            return
          end
          
          prompts = ["Number of Drawers", "Orientation", "Drawer Height from Bottom (mm)", "Drawer Height (mm)", "Drawer Front Thickness (mm)"]
          defaults = ["1", "Vertical", "100", "100", "18"]
          list = ["", "Vertical|Horizontal", "", "", ""]
          
          result = UI.inputbox(prompts, defaults, list, "Add Drawer #{position} Partition in #{target_section[:name]}")
          return unless result
          
          num_drawers = result[0].to_i
          orientation = result[1]
          height_from_bottom = result[2].to_f.mm
          drawer_height = result[3].to_f.mm
          drawer_front_thickness = result[4].to_f.mm
          
          if num_drawers <= 0
            UI.messagebox("Number of drawers must be greater than 0.")
            return
          end
          
          panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
          new_z = panel_thickness + height_from_bottom
          
          # Add drawers to the target section
          add_drawers_to_section_at_position(cabinet_group, target_section, new_z, num_drawers, drawer_height, drawer_front_thickness, orientation)
          UI.messagebox("#{num_drawers} drawer(s) added #{position} of partition in #{target_section[:name]} successfully!")
        end
      end
      
      # Add drawers at specific Z position (with quantity and orientation)
      def add_drawers_at_position(cabinet_group, z_position, num_drawers, drawer_height, drawer_front_thickness, orientation = "Horizontal")
        model = Sketchup.active_model
        model.start_operation('Add Drawers at Position', true)
        
        width = cabinet_group.get_attribute('DCC', 'width')
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        drawer_depth = depth - back_inset - back_thickness - 20.mm
        inner_width = width - (2 * panel_thickness)
        
        # Get existing drawer count
        existing_drawers = get_full_cabinet_drawers(cabinet_group)
        existing_count = existing_drawers.length
        
        if orientation == "Vertical"
          # Vertical arrangement: divide width by quantity (side by side)
          gap = 2.mm # Gap between vertical drawers
          # Calculate drawer width accounting for all gaps: (total_width - (n-1)*gap) / n
          drawer_width = (inner_width - ((num_drawers - 1) * gap)) / num_drawers.to_f
          
          # Validate minimum drawer width
          if drawer_width < 50.mm
            UI.messagebox("Drawers are too narrow. Each drawer width would be #{drawer_width.to_mm.round(1)}mm. Reduce quantity or use horizontal arrangement.")
            model.abort_operation
            return
          end
          
          # Validate position
          if z_position + drawer_height > height - panel_thickness
            UI.messagebox("Drawer extends beyond cabinet height.")
            model.abort_operation
            return
          end
          
          # Add drawers side by side (vertical arrangement)
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_x = panel_thickness + ((i - 1) * (drawer_width + gap))
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', -1)
            drawer_group.set_attribute('DCC', 'section_name', 'Full Cabinet')
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'vertical')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([drawer_x, 0, z_position])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        else
          # Horizontal arrangement: stack vertically
          drawer_width = inner_width
          
          # Validate position and check if all drawers fit
          total_drawer_height = num_drawers * drawer_height
          if z_position + total_drawer_height > height - panel_thickness
            UI.messagebox("Drawers extend beyond cabinet height. Total height #{total_drawer_height.to_mm}mm exceeds available space.")
            model.abort_operation
            return
          end
          
          # Calculate spacing
          spacing = drawer_height
          
          # Add drawers stacked vertically
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_z = z_position + ((i - 1) * spacing)
            
            # Check if drawer would exceed cabinet height
            if drawer_z + drawer_height > height - panel_thickness
              UI.messagebox("Warning: Drawer #{i} would exceed cabinet height. Only #{i - 1} drawer(s) added.")
              break
            end
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', -1)
            drawer_group.set_attribute('DCC', 'section_name', 'Full Cabinet')
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'horizontal')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([panel_thickness, 0, drawer_z])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        end
        
        model.commit_operation
      end
      
      # Legacy method for single drawer (for backward compatibility)
      def add_drawer_at_position(cabinet_group, z_position, drawer_height, drawer_front_thickness)
        add_drawers_at_position(cabinet_group, z_position, 1, drawer_height, drawer_front_thickness, "Horizontal")
      end
      
      # Add drawers to section at specific position (with quantity and orientation)
      def add_drawers_to_section_at_position(cabinet_group, section, z_position, num_drawers, drawer_height, drawer_front_thickness, orientation = "Horizontal")
        model = Sketchup.active_model
        model.start_operation('Add Drawers to Section at Position', true)
        
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        section_width = section[:width]
        drawer_depth = depth - back_inset - back_thickness - 20.mm
        
        # Get existing drawer count for section
        existing_drawers = get_section_drawers(cabinet_group, section)
        existing_count = existing_drawers.length
        
        if orientation == "Vertical"
          # Vertical arrangement: divide width by quantity (side by side)
          gap = 2.mm # Gap between vertical drawers
          # Calculate drawer width accounting for all gaps: (total_width - (n-1)*gap) / n
          drawer_width = (section_width - ((num_drawers - 1) * gap)) / num_drawers.to_f
          
          # Validate minimum drawer width
          if drawer_width < 50.mm
            UI.messagebox("Drawers are too narrow. Each drawer width would be #{drawer_width.to_mm.round(1)}mm. Reduce quantity or use horizontal arrangement.")
            model.abort_operation
            return
          end
          
          # Validate position
          if z_position + drawer_height > height - panel_thickness
            UI.messagebox("Drawer extends beyond cabinet height.")
            model.abort_operation
            return
          end
          
          # Add drawers side by side (vertical arrangement)
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_x = section[:left_x] + ((i - 1) * (drawer_width + gap))
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - #{section[:name]} DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', section[:index])
            drawer_group.set_attribute('DCC', 'section_name', section[:name])
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'vertical')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([drawer_x, 0, z_position])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        else
          # Horizontal arrangement: stack vertically
          drawer_width = section_width
          
          # Validate position and check if all drawers fit
          total_drawer_height = num_drawers * drawer_height
          if z_position + total_drawer_height > height - panel_thickness
            UI.messagebox("Drawers extend beyond cabinet height. Total height #{total_drawer_height.to_mm}mm exceeds available space.")
            model.abort_operation
            return
          end
          
          # Calculate spacing
          spacing = drawer_height
          
          # Add drawers stacked vertically
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_z = z_position + ((i - 1) * spacing)
            
            # Check if drawer would exceed cabinet height
            if drawer_z + drawer_height > height - panel_thickness
              UI.messagebox("Warning: Drawer #{i} would exceed cabinet height. Only #{i - 1} drawer(s) added.")
              break
            end
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - #{section[:name]} DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', section[:index])
            drawer_group.set_attribute('DCC', 'section_name', section[:name])
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'horizontal')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([section[:left_x], 0, drawer_z])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        end
        
        model.commit_operation
      end
      
      # Legacy method for single drawer (for backward compatibility)
      def add_drawer_to_section_at_position(cabinet_group, section, z_position, drawer_height, drawer_front_thickness)
        add_drawers_to_section_at_position(cabinet_group, section, z_position, 1, drawer_height, drawer_front_thickness, "Horizontal")
      end
      
      # Show dialog to add shelf to specific section
      def show_add_shelf_to_section_dialog(cabinet_group, section)
        prompts = ["Number of Shelves", "Shelf Thickness (mm)"]
        defaults = ["1", "18"]
        
        result = UI.inputbox(prompts, defaults, "Add Shelves to #{section[:name]}")
        return unless result
        
        num_shelves = result[0].to_i
        shelf_thickness = result[1].to_f.mm
        
        if num_shelves <= 0
          UI.messagebox("Number of shelves must be greater than 0.")
          return
        end
        
        add_shelf_to_section(cabinet_group, section, num_shelves, shelf_thickness)
        UI.messagebox("#{num_shelves} shelf/shelves added to #{section[:name]} successfully!")
      end
      
      # Add shelf to specific section
      def add_shelf_to_section(cabinet_group, section, num_shelves, shelf_thickness)
        model = Sketchup.active_model
        model.start_operation('Add Shelf to Section', true)
        
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        # Section-specific dimensions
        shelf_width = section[:width]
        shelf_depth = depth - back_inset - back_thickness
        inner_height = height - (2 * panel_thickness)
        
        # Validate section dimensions
        if shelf_width <= 0 || shelf_depth <= 0
          UI.messagebox("Section dimensions are invalid. Cannot add shelf.")
          model.abort_operation
          return
        end
        
        # Calculate spacing
        spacing = inner_height / (num_shelves + 1)
        
        # Get existing shelf count for this section
        existing_shelves = get_section_shelves(cabinet_group, section)
        existing_count = existing_shelves.length
        
        # Add shelves
        (1..num_shelves).each do |i|
          shelf_z = panel_thickness + (i * spacing)
          shelf_index = existing_count + i
          
          shelf_def = create_panel_component("#{cabinet_name} - #{section[:name]} SHELF #{shelf_index}", shelf_width, shelf_depth, shelf_thickness)
          instance = cabinet_group.entities.add_instance(shelf_def, [section[:left_x], 0, shelf_z])
          instance.set_attribute('DCC', 'panel_type', 'section_shelf')
          instance.set_attribute('DCC', 'section_index', section[:index])
          instance.set_attribute('DCC', 'section_name', section[:name])
        end
        
        model.commit_operation
      end
      
      # Get shelves for a specific section
      def get_section_shelves(cabinet_group, section)
        shelves = []
        cabinet_group.entities.each do |entity|
          if entity.is_a?(Sketchup::ComponentInstance)
            if entity.get_attribute('DCC', 'panel_type') == 'section_shelf'
              section_index = entity.get_attribute('DCC', 'section_index')
              if section_index == section[:index]
                shelves << entity
              end
            end
          end
        end
        shelves
      end
      
      # Show dialog to add drawer to section
      def show_add_drawer_to_section_dialog(cabinet_group, section)
        prompts = ["Number of Drawers", "Orientation", "Drawer Height (mm)", "Drawer Front Thickness (mm)"]
        defaults = ["1", "Vertical", "100", "18"]
        list = ["", "Vertical|Horizontal", "", ""]
        
        result = UI.inputbox(prompts, defaults, list, "Add Drawers to #{section[:name]}")
        return unless result
        
        num_drawers = result[0].to_i
        orientation = result[1]
        drawer_height = result[2].to_f.mm
        drawer_front_thickness = result[3].to_f.mm
        
        if num_drawers <= 0
          UI.messagebox("Number of drawers must be greater than 0.")
          return
        end
        
        add_drawer_to_section(cabinet_group, section, num_drawers, drawer_height, drawer_front_thickness, orientation)
        UI.messagebox("#{num_drawers} drawer/drawers added to #{section[:name]} successfully!")
      end
      
      # Add drawer to specific section
      def add_drawer_to_section(cabinet_group, section, num_drawers, drawer_height, drawer_front_thickness, orientation = "Horizontal")
        model = Sketchup.active_model
        model.start_operation('Add Drawer to Section', true)
        
        depth = cabinet_group.get_attribute('DCC', 'depth')
        height = cabinet_group.get_attribute('DCC', 'height')
        panel_thickness = cabinet_group.get_attribute('DCC', 'panel_thickness')
        back_thickness = cabinet_group.get_attribute('DCC', 'back_thickness')
        back_inset = cabinet_group.get_attribute('DCC', 'back_inset')
        cabinet_name = cabinet_group.get_attribute('DCC', 'cabinet_name')
        
        # Section-specific dimensions
        section_width = section[:width]
        drawer_depth = depth - back_inset - back_thickness - 20.mm # Leave some clearance
        inner_height = height - (2 * panel_thickness)
        
        # Validate section dimensions
        if section_width <= 0 || drawer_depth <= 0
          UI.messagebox("Section dimensions are invalid. Cannot add drawer.")
          model.abort_operation
          return
        end
        
        # Get existing drawer count for this section
        existing_drawers = get_section_drawers(cabinet_group, section)
        existing_count = existing_drawers.length
        
        if orientation == "Vertical"
          # Vertical arrangement: divide width by quantity (side by side)
          gap = 2.mm # Gap between vertical drawers
          # Calculate drawer width accounting for all gaps: (total_width - (n-1)*gap) / n
          drawer_width = (section_width - ((num_drawers - 1) * gap)) / num_drawers.to_f
          
          # Validate minimum drawer width
          if drawer_width < 50.mm
            UI.messagebox("Drawers are too narrow. Each drawer width would be #{drawer_width.to_mm.round(1)}mm. Reduce quantity or use horizontal arrangement.")
            model.abort_operation
            return
          end
          
          # Check if drawers fit in height (only need space for one drawer height)
          if drawer_height > inner_height
            UI.messagebox("Drawer height #{drawer_height.to_mm}mm exceeds available height #{inner_height.to_mm}mm.")
            model.abort_operation
            return
          end
          
          # Calculate starting Z position (stack on top of existing drawers)
          bottom_z = panel_thickness
          if existing_drawers.any?
            max_z = existing_drawers.map do |drawer|
              drawer_transformation = drawer.transformation
              bbox = drawer.bounds
              max_point = bbox.max.transform(drawer_transformation)
              max_point.z
            end.max
            bottom_z = [max_z, panel_thickness].max
          end
          
          # Add drawers side by side (vertical arrangement)
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_x = section[:left_x] + ((i - 1) * (drawer_width + gap))
            drawer_z = bottom_z
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - #{section[:name]} DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', section[:index])
            drawer_group.set_attribute('DCC', 'section_name', section[:name])
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'vertical')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([drawer_x, 0, drawer_z])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        else
          # Horizontal arrangement: stack vertically (original behavior)
          # Check if drawers fit
          total_drawer_height = num_drawers * drawer_height
          if total_drawer_height > inner_height
            UI.messagebox("Drawers do not fit in section. Total height #{total_drawer_height.to_mm}mm exceeds available #{inner_height.to_mm}mm.")
            model.abort_operation
            return
          end
          
          drawer_width = section_width
          
          # Calculate starting Z position (stack on top of existing drawers)
          bottom_z = panel_thickness
          if existing_drawers.any?
            max_z = existing_drawers.map do |drawer|
              drawer_transformation = drawer.transformation
              bbox = drawer.bounds
              max_point = bbox.max.transform(drawer_transformation)
              max_point.z
            end.max
            bottom_z = [max_z, panel_thickness].max
          end
          
          # Calculate spacing (stack drawers from bottom)
          spacing = drawer_height
          
          # Add drawers (create as groups for easy editing)
          (1..num_drawers).each do |i|
            drawer_index = existing_count + i
            drawer_z = bottom_z + ((i - 1) * spacing)
            
            # Check if drawer would exceed cabinet height
            if drawer_z + drawer_height > height - panel_thickness
              UI.messagebox("Warning: Drawer #{i} would exceed cabinet height. Only #{i - 1} drawer(s) added.")
              break
            end
            
            # Create drawer group
            drawer_group = cabinet_group.entities.add_group
            drawer_group.name = "#{cabinet_name} - #{section[:name]} DRAWER #{drawer_index}"
            drawer_group.set_attribute('DCC', 'is_drawer', true)
            drawer_group.set_attribute('DCC', 'section_index', section[:index])
            drawer_group.set_attribute('DCC', 'section_name', section[:name])
            drawer_group.set_attribute('DCC', 'drawer_index', drawer_index)
            drawer_group.set_attribute('DCC', 'drawer_orientation', 'horizontal')
            
            # Position drawer group
            drawer_group.transformation = Geom::Transformation.translation([section[:left_x], 0, drawer_z])
            
            # Create drawer components
            create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
          end
        end
        
        model.commit_operation
      end
      
      # Helper method to create drawer components
      def create_drawer_components(drawer_group, cabinet_name, drawer_index, drawer_width, drawer_depth, drawer_height, drawer_front_thickness)
        # Create drawer bottom
        drawer_bottom = create_panel_component("#{cabinet_name} - DRAWER #{drawer_index} BOTTOM", drawer_width, drawer_depth, 5.mm)
        bottom_instance = drawer_group.entities.add_instance(drawer_bottom, [0, 0, 0])
        
        # Create drawer front
        drawer_front = create_panel_component("#{cabinet_name} - DRAWER #{drawer_index} FRONT", drawer_width, drawer_front_thickness, drawer_height)
        front_instance = drawer_group.entities.add_instance(drawer_front, [0, -drawer_front_thickness, 0])
        
        # Create drawer sides (left and right)
        side_depth = drawer_depth
        side_height = drawer_height - 5.mm # Subtract bottom thickness
        side_thickness = 5.mm
        
        left_side = create_panel_component("#{cabinet_name} - DRAWER #{drawer_index} LEFT SIDE", side_thickness, side_depth, side_height)
        left_instance = drawer_group.entities.add_instance(left_side, [0, 0, 5.mm])
        
        right_side = create_panel_component("#{cabinet_name} - DRAWER #{drawer_index} RIGHT SIDE", side_thickness, side_depth, side_height)
        right_instance = drawer_group.entities.add_instance(right_side, [drawer_width - side_thickness, 0, 5.mm])
        
        # Create drawer back
        back_width = drawer_width - (2 * side_thickness)
        back_height = side_height
        drawer_back = create_panel_component("#{cabinet_name} - DRAWER #{drawer_index} BACK", back_width, side_thickness, back_height)
        back_instance = drawer_group.entities.add_instance(drawer_back, [side_thickness, side_depth, 5.mm])
      end
      
      # Get drawers for a specific section
      def get_section_drawers(cabinet_group, section)
        drawers = []
        cabinet_group.entities.each do |entity|
          if entity.is_a?(Sketchup::Group)
            if entity.get_attribute('DCC', 'is_drawer')
              section_index = entity.get_attribute('DCC', 'section_index')
              if section_index == section[:index]
                drawers << entity
              end
            end
          end
        end
        drawers
      end
      
      private

      def is_cabinet_group?(selection)
        return false unless selection.is_a?(Sketchup::Group)

        if selection.get_attribute('DCC', 'is_cabinet')
          return true
        end

        group_name = selection.name.to_s
        has_cabinet_attributes = selection.get_attribute('DCC', 'cabinet_name') ||
                                 selection.get_attribute('DCC', 'width') ||
                                 selection.get_attribute('DCC', 'height') ||
                                 selection.get_attribute('DCC', 'depth')

        has_panel_components = false
        begin
          selection.entities.each do |entity|
            if entity.is_a?(Sketchup::ComponentInstance)
              if entity.definition.name.to_s.match?(/LEFT|RIGHT|TOP|BOTTOM/i)
                has_panel_components = true
                break
              end
            end
          end
        rescue => e
        end

        if group_name.match?(/Cabinet/i) || has_cabinet_attributes || has_panel_components
          selection.set_attribute('DCC', 'is_cabinet', true)
          return true
        end

        false
      end

      def is_panel_component?(instance)
        return false unless instance.is_a?(Sketchup::ComponentInstance)

        definition = instance.definition

        is_panel = definition.get_attribute('DCC', 'is_panel') ||
                   instance.get_attribute('DCC', 'is_standalone_panel') ||
                   instance.get_attribute('DCC', 'panel_type')

        has_dcc_attributes = definition.get_attribute('DCC', 'width') ||
                             definition.get_attribute('DCC', 'height') ||
                             definition.get_attribute('DCC', 'depth') ||
                             instance.get_attribute('DCC', 'width') ||
                             instance.get_attribute('DCC', 'height') ||
                             instance.get_attribute('DCC', 'thickness')

        is_panel_by_name = definition.name.to_s.match?(/LEFT|RIGHT|TOP|BOTTOM|Panel|^p\d+/i)

        is_panel_by_shape = false
        begin
          bbox = instance.bounds
          if bbox.valid?
            dims = [(bbox.max - bbox.min).x.abs, (bbox.max - bbox.min).y.abs, (bbox.max - bbox.min).z.abs].sort
            is_panel_by_shape = dims[0] < 100.mm && dims[1] >= 50.mm && dims[2] >= 50.mm
          end
        rescue => e
        end

        is_panel || has_dcc_attributes || is_panel_by_name || is_panel_by_shape
      end

      def existing_cabinet_names
        model = Sketchup.active_model
        return [] unless model

        model.entities.grep(Sketchup::Group).map do |entity|
          next unless entity.get_attribute('DCC', 'is_cabinet')
          entity.get_attribute('DCC', 'cabinet_name')
        end.compact
      end

      def cabinet_name_taken?(name)
        comparison_target = name.to_s.strip
        return false if comparison_target.empty?

        existing_cabinet_names.any? do |existing|
          existing.to_s.casecmp?(comparison_target)
        end
      end

      def existing_panel_names
        model = Sketchup.active_model
        return [] unless model

        model.entities.grep(Sketchup::ComponentInstance).map do |entity|
          next unless entity.get_attribute('DCC', 'is_standalone_panel')
          entity.get_attribute('DCC', 'name')
        end.compact
      end

      def panel_name_taken?(name)
        comparison_target = name.to_s.strip
        return false if comparison_target.empty?

        existing_panel_names.any? do |existing|
          existing.to_s.casecmp?(comparison_target)
        end
      end

      # Generate a random name with prefix
      def generate_random_name(prefix = 'Item')
        loop do
          # Generate random suffix: 4 random alphanumeric characters
          random_suffix = (0...4).map { ('A'..'Z').to_a[rand(26)] }.join + (0...4).map { (0..9).to_a[rand(10)] }.join
          random_name = "#{prefix}_#{random_suffix}"
          
          # Check if name is unique (for both cabinets and panels)
          unless cabinet_name_taken?(random_name) || panel_name_taken?(random_name)
            return random_name
          end
        end
      end

      # Ensure cabinet name is unique, generate random if duplicate
      def ensure_unique_cabinet_name(original_name)
        return generate_random_name('Cabinet') if original_name.nil? || original_name.to_s.strip.empty?
        
        name = original_name.to_s.strip
        return generate_random_name('Cabinet') if name.empty?
        
        # If name is taken, generate random name
        if cabinet_name_taken?(name)
          return generate_random_name('Cabinet')
        end
        
        name
      end

      # Ensure panel name is unique, generate random if duplicate
      def ensure_unique_panel_name(original_name)
        return nil if original_name.nil? || original_name.to_s.strip.empty?
        
        name = original_name.to_s.strip
        return nil if name.empty?
        
        # If name is taken, generate random name
        if panel_name_taken?(name)
          return generate_random_name('Panel')
        end
        
        name
      end

      def current_cabinet_numbers
        existing_cabinet_names.map do |name|
          match = name.to_s.match(/\AC(\d+)\z/i)
          match[1].to_i if match
        end.compact
      end

      def update_counter_from_name(name)
        match = name.to_s.match(/\AC(\d+)\z/i)
        return unless match

        numeric_value = match[1].to_i
        @cabinet_counter = [@cabinet_counter, numeric_value].max
        @deleted_cabinet_numbers.delete(numeric_value)
      end

      # Get or create dialog
      def get_or_create_dialog(id, title, width, height)
        if @dialogs[id] && @dialogs[id].visible?
          @dialogs[id].bring_to_front
          return @dialogs[id]
        end
        
        @dialogs[id] = UI::HtmlDialog.new(
          dialog_title: title,
          preferences_key: "com.aj.dcc.#{id}",
          scrollable: true,
          resizable: true,
          width: width,
          height: height,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        
        @dialogs[id]
      end
      
    end
    
    # Selection Observer for property panel
    class CabinetSelectionObserver < Sketchup::SelectionObserver
      def initialize(manager)
        @manager = manager
      end
      
      def onSelectionBulkChange(selection)
        # If the Cabinet Setup dialog is open, keep it in sync with the
        # current selection so it switches between edit and create modes
        # without needing to close/reopen the dialog. Use the same JS pattern
        # as when the dialog is first shown.
        cab_dialog = @manager.instance_variable_get(:@dialogs)['cabinet_setup']
        if cab_dialog && cab_dialog.visible?
          begin
            cab_dialog.execute_script("if (window.sketchup) { window.sketchup.getSelectedCabinetProperties(); }")
          rescue => e
            # Silently ignore dialog update errors
          end
        end
        
        # Update property panel dialog to follow current selection (like real-time update)
        if @manager.update_property_panel_on_selection
          prop_dialog = @manager.instance_variable_get(:@dialogs)['property_panel']
          if prop_dialog && prop_dialog.visible?
            begin
              model = Sketchup.active_model
              selection_all = model.selection.to_a
              component_instances = selection_all.select { |e| e.is_a?(Sketchup::ComponentInstance) }
              if component_instances.any?
                # Update manager's current component(s)
                @manager.instance_variable_set(:@current_panel_component, component_instances.first)
                @manager.instance_variable_set(:@current_panel_components, component_instances)
                
                data = @manager.extract_component_data(component_instances.first)
                data[:selectionCount] = component_instances.length
                prop_dialog.execute_script("window.loadComponentData(#{data.to_json});")
              end
            rescue => e
              # Silently ignore selection update errors to avoid disrupting user
            end
          end
        end
        
        return if selection.count != 1
        
        selected = selection.first
        
        # Check if this is a double-click
        is_double_click = @manager.check_double_click(selected)
        
        # Only show property panel on double-click
        return unless is_double_click
        
        # Show property panel for DCC components (both cabinet panels and standalone panels)
        if selected.is_a?(Sketchup::ComponentInstance) && @manager.is_panel_component?(selected)
          @manager.show_property_panel(selected)
        end
      end
    end
    
    # Create toolbar
    def self.create_toolbar
      toolbar = UI::Toolbar.new("Dynamic Cabinet Creator")
      
      # Cabinet Setup button
      cmd_setup = UI::Command.new("Cabinet Setup") {
        @manager ||= CabinetManager.new
        @manager.show_cabinet_setup_dialog
      }
      cmd_setup.small_icon = File.join(__dir__, 'icons', 'setup.svg')
      cmd_setup.large_icon = File.join(__dir__, 'icons', 'setup.svg')
      cmd_setup.tooltip = "Set Cabinet Name, Width, Depth, Height"
      toolbar.add_item(cmd_setup)
      
      # Cabinet Structure button
      cmd_structure = UI::Command.new("Cabinet Structure") {
        @manager ||= CabinetManager.new
        @manager.show_cabinet_structure_dialog
      }
      cmd_structure.small_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_structure.large_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_structure.tooltip = "Set Cabinet Panel Properties"
      toolbar.add_item(cmd_structure)
      
      # Shelves & Partitions button
      cmd_shelves = UI::Command.new("Shelves & Partitions") {
        @manager ||= CabinetManager.new
        @manager.show_shelves_partitions_dialog
      }
      cmd_shelves.small_icon = File.join(__dir__, 'icons', 'shelves.svg')
      cmd_shelves.large_icon = File.join(__dir__, 'icons', 'shelves.svg')
      cmd_shelves.tooltip = "Add or Modify Shelves and Vertical Panels"
      toolbar.add_item(cmd_shelves)
      
      # Shutters/Doors button
      cmd_shutters = UI::Command.new("Shutters / Doors") {
        @manager ||= CabinetManager.new
        @manager.show_shutters_dialog
      }
      cmd_shutters.small_icon = File.join(__dir__, 'icons', 'shutters.svg')
      cmd_shutters.large_icon = File.join(__dir__, 'icons', 'shutters.svg')
      cmd_shutters.tooltip = "Add or Edit Cabinet Doors"
      toolbar.add_item(cmd_shutters)

      # Panel Creation button
      cmd_panel = UI::Command.new("Panel Creation") {
        @manager ||= CabinetManager.new
        @manager.show_panel_creation_dialog
      }
      cmd_panel.small_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_panel.large_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_panel.tooltip = "Create Standalone Panels"
      toolbar.add_item(cmd_panel)
      
      # Edit Panel button - directly opens property panel without popup
      cmd_edit_panel = UI::Command.new("Edit Panel") {
        @manager ||= CabinetManager.new
        model = Sketchup.active_model
        selection_all = model.selection.to_a
        component_instances = selection_all.select { |e| e.is_a?(Sketchup::ComponentInstance) }
        selection = component_instances.first
        
        if selection
          @manager.show_property_panel(selection)
        else
          UI.messagebox("Please select a panel component first!")
        end
      }
      cmd_edit_panel.small_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_edit_panel.large_icon = File.join(__dir__, 'icons', 'structure.svg')
      cmd_edit_panel.tooltip = "Edit Panel Properties"
      toolbar.add_item(cmd_edit_panel)
      
      toolbar.show
    end
    
    # Initialize extension
    unless file_loaded?(__FILE__)
      # Create toolbar
      create_toolbar
      
      # Add context menu provider
      @manager ||= CabinetManager.new
      manager = @manager  # Capture in local variable for block closure
      UI.add_context_menu_handler do |menu|
        # Get the selected entity
        selection = Sketchup.active_model.selection
        next if selection.empty?
        
        # Get the first selected entity (context menu appears when right-clicking on selected items)
        selected = selection.first
        next unless selected
        
        # Check if it's a component/panel
        if selected.is_a?(Sketchup::ComponentInstance) && manager.is_panel_component?(selected)
          selected_panel = selected
          menu.add_separator
          menu.add_item('Component Properties') {
            manager.show_component_action_dialog(selected_panel)
          }
        elsif selected.is_a?(Sketchup::Group) && manager.is_cabinet_group?(selected)
          selected_cabinet = selected
          menu.add_separator
          menu.add_item('Edit Cabinet Properties') {
            manager.show_edit_cabinet_properties_dialog(selected_cabinet)
          }
          menu.add_item('Cabinet Actions') {
            manager.show_main_cabinet_action_dialog(selected_cabinet)
          }
        end
      end
      
      # Add menu items
      menu = UI.menu('Extensions')
      submenu = menu.add_submenu('Dynamic Cabinet Creator')
      submenu.add_item('Cabinet Setup') {
        @manager ||= CabinetManager.new
        @manager.show_cabinet_setup_dialog
      }
      submenu.add_item('Cabinet Structure') {
        @manager ||= CabinetManager.new
        @manager.show_cabinet_structure_dialog
      }
      submenu.add_item('Shelves & Partitions') {
        @manager ||= CabinetManager.new
        @manager.show_shelves_partitions_dialog
      }
      submenu.add_item('Shutters / Doors') {
        @manager ||= CabinetManager.new
        @manager.show_shutters_dialog
      }
      submenu.add_item('Panel Creation') {
        @manager ||= CabinetManager.new
        @manager.show_panel_creation_dialog
      }
      submenu.add_separator
      submenu.add_item('Cabinet Actions (Shelves/Partitions/Drawers)') {
        @manager ||= CabinetManager.new
        @manager.show_cabinet_action_dialog
      }
      submenu.add_separator
      submenu.add_item('Hide All DCC Dimensions & Names') {
        @manager ||= CabinetManager.new
        @manager.hide_all_dcc_dimensions_and_labels
      }
      submenu.add_item('Show All DCC Dimensions & Names') {
        @manager ||= CabinetManager.new
        @manager.show_all_dcc_dimensions_and_labels
      }
      
      file_loaded(__FILE__)
    end
    
  end
end
