import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
  Logger,
  Param,
} from '@nestjs/common';
import { ApiOperation, ApiParam, ApiResponse, ApiTags } from '@nestjs/swagger';
import { ApiResponseDto } from '../../common/dto/api-response.dto';
import { CategoriesService } from './categories.service';
import { CategoryResponseDto } from './dto';

@ApiTags('Categories')
@Controller('categories')
export class CategoriesController {
  private readonly logger = new Logger(CategoriesController.name);

  constructor(private readonly categoriesService: CategoriesService) {}

  @Get('menu/:menuId')
  @ApiOperation({
    summary: 'Get all categories by menu ID',
    description:
      'Retrieves all active categories for a specific menu with their details',
  })
  @ApiParam({
    name: 'menuId',
    type: String,
    description: 'ID of the menu to get categories from',
  })
  @ApiResponse({
    status: 200,
    description: 'Categories retrieved successfully',
    type: ApiResponseDto<CategoryResponseDto[]>,
  })
  @ApiResponse({
    status: 404,
    description: 'Menu not found',
    schema: {
      example: {
        success: false,
        message: 'Menu not found',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  @ApiResponse({
    status: 500,
    description: 'Internal server error',
    schema: {
      example: {
        success: false,
        message: 'Error retrieving categories',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  async findByMenuId(
    @Param('menuId') menuId: string,
  ): Promise<ApiResponseDto<CategoryResponseDto[]>> {
    try {
      this.logger.log(`Getting categories for menu: ${menuId}`);
      const categories = await this.categoriesService.findByMenuId(menuId);
      return new ApiResponseDto(
        true,
        'Categories retrieved successfully',
        categories,
      );
    } catch (error) {
      if (error instanceof HttpException) {
        throw error;
      }
      this.logger.error('Error retrieving categories', error);
      throw new HttpException(
        {
          success: false,
          message: 'Error retrieving categories',
          timestamp: new Date().toISOString(),
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }

  @Get(':id')
  @ApiOperation({
    summary: 'Get category by ID',
    description: 'Retrieves a specific category by its ID',
  })
  @ApiParam({
    name: 'id',
    type: String,
    description: 'ID of the category to retrieve',
  })
  @ApiResponse({
    status: 200,
    description: 'Category retrieved successfully',
    type: ApiResponseDto<CategoryResponseDto>,
  })
  @ApiResponse({
    status: 404,
    description: 'Category not found',
    schema: {
      example: {
        success: false,
        message: 'Category not found',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  @ApiResponse({
    status: 500,
    description: 'Internal server error',
    schema: {
      example: {
        success: false,
        message: 'Error retrieving category',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  async findById(
    @Param('id') id: string,
  ): Promise<ApiResponseDto<CategoryResponseDto>> {
    try {
      this.logger.log(`Getting category by ID: ${id}`);
      const category = await this.categoriesService.findById(id);
      return new ApiResponseDto(
        true,
        'Category retrieved successfully',
        category,
      );
    } catch (error) {
      if (error instanceof HttpException) {
        throw error;
      }
      this.logger.error('Error retrieving category', error);
      throw new HttpException(
        {
          success: false,
          message: 'Error retrieving category',
          timestamp: new Date().toISOString(),
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }
}
