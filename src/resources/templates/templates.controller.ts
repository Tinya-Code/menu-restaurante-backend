import { Controller, Get } from '@nestjs/common';
import { TemplatesService } from './templates.service';

@Controller('resources/templates')
export class TemplatesController {
  constructor(private readonly templatesService: TemplatesService) {}

  @Get()
  findAll() {
    return this.templatesService.findAll();
  }
}
