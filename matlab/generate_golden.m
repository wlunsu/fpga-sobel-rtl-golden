function generate_golden(project_root)
%GENERATE_GOLDEN Build deterministic input images and bit-exact Sobel data.
%
% The arithmetic intentionally mirrors rtl/sobel_operator.v:
%   magnitude = min(abs(Gx) + abs(Gy), 255)
% The complete outer border is forced to zero.

    if nargin < 1 || isempty(project_root)
        this_file = mfilename('fullpath');
        project_root = fileparts(fileparts(this_file));
    end

    width = 64;
    height = 64;

    cases_dir = fullfile(project_root, 'testdata', 'cases');
    preview_dir = fullfile(project_root, 'testdata', 'golden_preview');
    if ~exist(cases_dir, 'dir')
        mkdir(cases_dir);
    end
    if ~exist(preview_dir, 'dir')
        mkdir(preview_dir);
    end

    cases = cell(6, 2);

    cases{1, 1} = 'constant';
    cases{1, 2} = uint8(73 * ones(height, width));

    vertical = uint8(20 * ones(height, width));
    vertical(:, (width / 2 + 1):end) = 220;
    cases{2, 1} = 'vertical_step';
    cases{2, 2} = vertical;

    horizontal = uint8(30 * ones(height, width));
    horizontal((height / 2 + 1):end, :) = 200;
    cases{3, 1} = 'horizontal_step';
    cases{3, 2} = horizontal;

    impulse = zeros(height, width, 'uint8');
    impulse(height / 2, width / 2) = 255;
    cases{4, 1} = 'impulse';
    cases{4, 2} = impulse;

    [xx, yy] = meshgrid(0:(width - 1), 0:(height - 1));
    structured = uint8(mod(3 * xx + 5 * yy, 256));
    structured(12:28, 10:26) = 235;
    structured(37:53, 34:56) = 18;
    structured(abs(xx - yy) <= 1) = 255;
    cases{5, 1} = 'structured';
    cases{5, 2} = structured;

    rng(20260818, 'twister');
    cases{6, 1} = 'random_seeded';
    cases{6, 2} = uint8(randi([0, 255], height, width));

    manifest_path = fullfile(project_root, 'testdata', 'manifest.csv');
    manifest_file = fopen(manifest_path, 'w');
    assert(manifest_file >= 0, 'Could not create manifest: %s', manifest_path);
    manifest_cleanup = onCleanup(@() fclose(manifest_file));
    fprintf(manifest_file, 'case_name,width,height,input_mem,golden_mem,rtl_mem\n');

    fprintf('Generating MATLAB Golden Model cases in %s\n', cases_dir);
    for index = 1:size(cases, 1)
        case_name = cases{index, 1};
        input_image = cases{index, 2};
        golden_image = sobel_integer_reference(input_image);

        input_relative = fullfile('testdata', 'cases', [case_name '_input.mem']);
        golden_relative = fullfile('testdata', 'cases', [case_name '_golden.mem']);
        rtl_relative = fullfile('testdata', 'results', [case_name '_rtl.mem']);

        write_hex_mem(fullfile(project_root, input_relative), input_image);
        write_hex_mem(fullfile(project_root, golden_relative), golden_image);
        imwrite(input_image, fullfile(preview_dir, [case_name '_input.png']));
        imwrite(golden_image, fullfile(preview_dir, [case_name '_golden.png']));

        % Manifests use forward slashes so both MATLAB and Python can read it.
        fprintf(manifest_file, '%s,%d,%d,%s,%s,%s\n', ...
            case_name, width, height, ...
            strrep(input_relative, '\', '/'), ...
            strrep(golden_relative, '\', '/'), ...
            strrep(rtl_relative, '\', '/'));

        fprintf('  %-16s input=%4d pixels, nonzero golden=%4d\n', ...
            case_name, numel(input_image), nnz(golden_image));
    end

    clear manifest_cleanup;
    fprintf('Golden Model generation complete: %s\n', manifest_path);
end

function output_image = sobel_integer_reference(input_image)
    [height, width] = size(input_image);
    output_image = zeros(height, width, 'uint8');

    for row = 2:(height - 1)
        for col = 2:(width - 1)
            p = int32(input_image((row - 1):(row + 1), (col - 1):(col + 1)));

            gx = (p(1, 3) + 2 * p(2, 3) + p(3, 3)) ...
               - (p(1, 1) + 2 * p(2, 1) + p(3, 1));
            gy = (p(3, 1) + 2 * p(3, 2) + p(3, 3)) ...
               - (p(1, 1) + 2 * p(1, 2) + p(1, 3));

            magnitude = min(abs(gx) + abs(gy), int32(255));
            output_image(row, col) = uint8(magnitude);
        end
    end
end

function write_hex_mem(filename, image)
    file_id = fopen(filename, 'w');
    assert(file_id >= 0, 'Could not write memory file: %s', filename);
    cleanup = onCleanup(@() fclose(file_id));

    % MATLAB is column-major; transpose before reshape for row-major files.
    row_major_pixels = reshape(image.', [], 1);
    fprintf(file_id, '%02X\n', row_major_pixels);
    clear cleanup;
end

