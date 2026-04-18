import { Controller, Get, Param } from '@nestjs/common';
import { BannersService } from './banners.service';

@Controller('resources/banners')
export class BannersController {
  constructor(private readonly bannersService: BannersService) {}

  @Get('branch/:id')
  findByBranch(@Param('id') id: string) {
    return this.bannersService.findByBranchId(id);
  }
}
