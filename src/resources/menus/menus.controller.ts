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
import { MenusService } from './menus.service';
import { FullMenuResponseDto, MenuResponseDto } from './dto';

@ApiTags('Menus')
@Controller('menus')
export class MenusController {
  private readonly logger = new Logger(MenusController.name);

  constructor(private readonly menusService: MenusService) {}

  @Get('branch/:branchId')
  @ApiOperation({
    summary: 'Get menus by branch ID',
    description: 'Retrieves all active menus for a specific branch',
  })
  @ApiParam({
    name: 'branchId',
    type: String,
    description: 'ID of the branch to get menus from',
  })
  @ApiResponse({
    status: 200,
    description: 'Menus retrieved successfully',
    type: ApiResponseDto<MenuResponseDto[]>,
  })
  @ApiResponse({
    status: 500,
    description: 'Internal server error',
    schema: {
      example: {
        success: false,
        message: 'Error retrieving menus',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  async findByBranchId(
    @Param('branchId') branchId: string,
  ): Promise<ApiResponseDto<MenuResponseDto[]>> {
    try {
      this.logger.log(`Getting menus for branch: ${branchId}`);
      const menus = await this.menusService.findByBranchId(branchId);
      return new ApiResponseDto(true, 'Menus retrieved successfully', menus);
    } catch (error) {
      if (error instanceof HttpException) {
        throw error;
      }
      this.logger.error('Error retrieving menus', error);
      throw new HttpException(
        {
          success: false,
          message: 'Error retrieving menus',
          timestamp: new Date().toISOString(),
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }

  @Get(':id/full')
  @ApiOperation({
    summary: 'Get full menu with categories and products',
    description:
      'Retrieves a complete menu with all categories and their products nested',
  })
  @ApiParam({
    name: 'id',
    type: String,
    description: 'ID of the menu to retrieve',
  })
  @ApiResponse({
    status: 200,
    description: 'Menu retrieved successfully',
    type: ApiResponseDto<FullMenuResponseDto[]>,
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
        message: 'Error retrieving full menu',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  async getFullMenu(
    @Param('id') menuId: string,
  ): Promise<ApiResponseDto<FullMenuResponseDto[]>> {
    try {
      this.logger.log(`Getting full menu: ${menuId}`);
      const menu = await this.menusService.findFullMenu(menuId);
      return new ApiResponseDto(true, 'Menu retrieved successfully', menu);
    } catch (error) {
      if (error instanceof HttpException) {
        throw error;
      }
      this.logger.error('Error retrieving full menu', error);
      throw new HttpException(
        {
          success: false,
          message: 'Error retrieving full menu',
          timestamp: new Date().toISOString(),
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }
}
